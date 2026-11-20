import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '..', '..');
const binary = path.join(repo, 'zig-out', 'bin', 'fx');
const names = ['ListAgents', 'ReportFindings', 'SendMessage', 'mcp__gm__finish', 'mcp__gm__next_context', 'mcp__gm__run_code'];

function sourceFiles(dir, out) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) sourceFiles(full, out);
    else if (entry.name.endsWith('.zig') && !full.startsWith(path.join(repo, 'src', 'core', 'parity'))) out.push(full);
  }
  return out;
}

const sources = sourceFiles(path.join(repo, 'src'), []);
for (const name of names) {
  const hits = sources.filter((file) => fs.readFileSync(file, 'utf8').includes(name));
  assert.deepEqual(hits, [], name + ' is implemented in ' + hits.join(', ') + '; update the item 10 open report');
}

const result = spawnSync(binary, ['parity', '10', '--json'], { cwd: repo, encoding: 'utf8' });
assert.equal(result.status, 0, 'parity 10 exited ' + result.status + ': ' + result.stderr);
const report = JSON.parse(result.stdout);
assert.equal(report.item, 10, 'item is not 10');
assert.equal(report.offline, true, 'offline flag missing');
assert.equal(report.status, 'open', 'status is not open');
assert.equal(report.ok, false, 'ok must stay false while items are open');
assert.deepEqual(report.entries.map((entry) => entry.name), names, 'entries differ');
for (const entry of report.entries) {
  assert.equal(entry.status, 'open', entry.name + ' is not open');
  assert.ok(entry.reason.length > 0, entry.name + ' has no reason');
}
console.log(JSON.stringify({ item: 10, mode: 'binary', open: report.entries.length, unimplemented_verified: names.length, ok: true, status: 'open' }));
