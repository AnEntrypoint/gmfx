import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "../..");
const fx = path.resolve(root, "zig-out/bin/fx");
const stateDir = "/workspace/fx/work/acceptance";
const stateFile = path.join(stateDir, "item5-state.json");
const generationFile = path.join(stateDir, "item5-generation.txt");
const surfaceKeys = ["compacted_long_turn", "memory_fact", "push_notification", "resumed_session", "scheduled_wakeup"].sort();
const changedKeys = ["compacted_long_turn_revision", "memory_fact_revision", "push_notification_revision", "resumed_session_revision", "scheduled_wakeup_revision"].sort();
const surfaceNames = ["acp", "browser", "cli", "libfx"];

function parseOutput(result) {
    assert.equal(result.status, 0, "fx parity 5 failed: " + (result.error ? result.error.message : result.stderr || result.stdout));
    const text = String(result.stdout || "").trim();
    const start = text.indexOf("{");
    const end = text.lastIndexOf("}");
    assert.ok(start >= 0 && end > start, "missing JSON in fx output: " + text);
    return JSON.parse(text.slice(start, end + 1));
}

function findReport(value) {
    if (value === null || typeof value !== "object") return null;
    if (value.item === 5 && value.surfaces && value.state_changes) return value;
    for (const child of Object.values(value)) {
        if (typeof child === "string") {
            const trimmed = child.trim();
            if (trimmed.startsWith("{")) {
                try {
                    const nested = findReport(JSON.parse(trimmed));
                    if (nested) return nested;
                } catch {}
            }
        } else {
            const nested = findReport(child);
            if (nested) return nested;
        }
    }
    return null;
}

function runParity() {
    const result = spawnSync(fx, ["parity", "5", "--json"], { cwd: root, encoding: "utf8" });
    const report = findReport(parseOutput(result));
    assert.ok(report, "parity 5 report not found in fx output");
    return report;
}

function assertSurfaces(report) {
    assert.equal(report.item, 5);
    assert.equal(report.ok, true);
    assert.equal(report.status, "implemented");
    assert.equal(report.key_sets_equal, true);
    assert.deepEqual(report.keys.slice().sort(), surfaceKeys);
    assert.deepEqual(Object.keys(report.surfaces).sort(), surfaceNames);
    for (const name of surfaceNames) {
        assert.deepEqual(Object.keys(report.surfaces[name]).sort(), surfaceKeys);
        for (const key of surfaceKeys) {
            assert.deepEqual(report.surfaces[name][key], report.surfaces.cli[key]);
            assert.equal(typeof report.surfaces[name][key].value, "string");
            assert.equal(typeof report.surfaces[name][key].revision, "number");
        }
    }
}

function assertChanges(report) {
    const changes = report.state_changes;
    assert.deepEqual(changes.changed_keys.slice().sort(), changedKeys);
    assert.equal(changes.changed_count, changedKeys.length);
    assert.equal(changes.after_generation, changes.before_generation + 1);
    const surfaceRevisions = {
        compacted_long_turn: "compacted_long_turn_revision",
        memory_fact: "memory_fact_revision",
        push_notification: "push_notification_revision",
        resumed_session: "resumed_session_revision",
        scheduled_wakeup: "scheduled_wakeup_revision",
    };
    for (const [key, revisionKey] of Object.entries(surfaceRevisions)) {
        assert.equal(report.surfaces.cli[key].revision, changes.after[revisionKey]);
        assert.notEqual(changes.after[revisionKey], changes.before[revisionKey]);
        assert.ok(changes.after[revisionKey] > changes.before[revisionKey]);
    }
}

fs.mkdirSync(stateDir, { recursive: true });
fs.rmSync(stateFile, { force: true });
fs.rmSync(generationFile, { force: true });
const first = runParity();
assertSurfaces(first);
assertChanges(first);
assert.equal(first.generation, 1);
const firstState = fs.readFileSync(stateFile, "utf8");
const firstStateObject = JSON.parse(firstState);
assert.equal(firstStateObject.generation, 1);
const second = runParity();
assertSurfaces(second);
assertChanges(second);
assert.equal(second.generation, 2);
assert.equal(second.state_changes.before_generation, first.generation);
const secondState = fs.readFileSync(stateFile, "utf8");
const secondStateObject = JSON.parse(secondState);
assert.notEqual(secondState, firstState);
assert.equal(secondStateObject.generation, firstStateObject.generation + 1);
for (const key of changedKeys) {
    assert.equal(second.state_changes.before[key], first.state_changes.after[key]);
    assert.ok(second.state_changes.after[key] > first.state_changes.after[key]);
    assert.equal(secondStateObject.state_changes.after[key], second.state_changes.after[key]);
}
assert.equal(fs.readFileSync(generationFile, "utf8").trim(), "2");
console.log(JSON.stringify({
    item: 5,
    ok: true,
    generations: [first.generation, second.generation],
    keys: surfaceKeys,
    state_file: stateFile,
    witness: "parity 5 generations 1 and 2; cli, acp, libfx and browser share " + surfaceKeys.length + " keys; " + changedKeys.length + " revisions changed",
}));
