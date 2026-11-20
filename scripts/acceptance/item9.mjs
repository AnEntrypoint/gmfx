import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const repo = resolve(here, '..', '..');
const binary = join(repo, 'zig-out', 'bin', 'fx');
const source = readFileSync(join(repo, 'src', 'core', 'parity', 'item9.zig'), 'utf8');
for (const token of ['dangerouslyDisableSandbox', 'hooks.json', 'sandbox_bypass']) {
  assert.ok(source.includes(token), 'missing token ' + token);
}
assert.ok(!/disableSandbox\(\)/.test(source), 'real sandbox bypass found');

const result = spawnSync(binary, ['parity', '9', '--json'], { cwd: repo, encoding: 'utf8' });
assert.equal(result.status, 0, 'parity 9 exited ' + result.status + ': ' + result.stderr);
const report = JSON.parse(result.stdout);
assert.equal(report.item, 9, 'item is not 9');
assert.equal(report.offline, true, 'offline flag missing');
assert.equal(report.status, 'open', 'status is not open');
assert.equal(report.ok, false, 'ok must stay false while items are open');
assert.equal(report.sandbox_bypass, false, 'sandbox bypass reported');
const names = report.entries.map((entry) => entry.name);
assert.deepEqual(names, ['dangerouslyDisableSandbox', 'hooks.json'], 'entries differ');
for (const entry of report.entries) {
  assert.equal(entry.status, 'open', entry.name + ' is not open');
  assert.ok(entry.reason.length > 0, entry.name + ' has no reason');
}
console.log(JSON.stringify({ item: 9, mode: existsSync(binary) ? 'binary' : 'static', open: report.entries.length, sandbox_bypass: report.sandbox_bypass, ok: true, status: 'open' }));
