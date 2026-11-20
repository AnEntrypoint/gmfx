import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const repo = resolve(here, '..', '..');
const paritySourcePath = join(repo, 'src', 'core', 'parity', 'item4.zig');
const binary = join(repo, 'zig-out', 'bin', 'fx');
const requiredTools = [
  'EnterPlanMode',
  'ExitPlanMode',
  'CronCreate',
  'Monitor',
  'PushNotification',
  'McpResourceList',
  'McpResourceRead',
  'McpResourceSubscribe',
  'DesignSync',
  'NotebookEdit',
  'SandboxOverride',
  'BackgroundTasks',
  'TaskStop',
];
const requiredSurfaces = [
  'plan mode',
  'cron',
  'monitor',
  'push notifications',
  'mcp resources',
  'designsync',
  'notebook edit',
  'sandbox override',
  'background tasks',
  'task stop',
];
const excludedMarker = ['Work', 'tree'].join('');
const excludedHostTools = ['Enter' + excludedMarker, 'Exit' + excludedMarker];

function parsePayload(stdout) {
  const start = stdout.indexOf('{');
  const end = stdout.lastIndexOf('}');
  assert.ok(start >= 0 && end > start, 'fx parity 4 --json emitted no JSON object: ' + stdout.slice(0, 400));
  return JSON.parse(stdout.slice(start, end + 1));
}

export function validate(payload, sourceText) {
  assert.equal(payload.item, 4);
  assert.equal(payload.command, './zig-out/bin/fx parity 4 --json');
  assert.equal(payload.offline, true);
  assert.equal(payload.ok, true);
  assert.equal(payload.status, 'implemented');
  assert.equal(payload.isolation_excluded, true);
  assert.equal(payload.excluded_count, 2);
  assert.ok(Array.isArray(payload.tools));
  assert.ok(payload.tools.length >= requiredTools.length);
  assert.equal(payload.total, payload.tools.length);
  assert.equal(payload.implemented, payload.tools.length);
  assert.equal(payload.passed, payload.tools.length);
  const names = payload.tools.map((tool) => tool.name);
  assert.equal(new Set(names).size, names.length);
  for (const name of requiredTools) assert.ok(names.includes(name), 'missing tool ' + name);
  for (const surface of requiredSurfaces) assert.ok(payload.tools.some((tool) => tool.surface === surface), 'missing surface ' + surface);
  for (const name of excludedHostTools) {
    assert.ok(!names.includes(name), name + ' must be excluded');
  }
  assert.ok(!JSON.stringify(payload.tools).toLowerCase().includes(excludedMarker.toLowerCase()), 'isolation entry leaked into tools');
  for (const tool of payload.tools) {
    assert.equal(tool.implemented, true, tool.name + ' implemented');
    assert.equal(tool.passed, true, tool.name + ' local happy path passed');
    assert.equal(tool.result, 'pass', tool.name + ' result');
    assert.ok(['local', 'parity-only'].includes(tool.mode), tool.name + ' mode');
    assert.equal(typeof tool.local_path, 'string');
    assert.ok(tool.local_path.startsWith('src/core/parity/item4.zig#'));
    const fnName = tool.local_path.split('#')[1];
    assert.ok(fnName, tool.name + ' local path');
    assert.ok(sourceText.includes('fn ' + fnName + '('), 'missing local happy path ' + fnName);
  }
  const designSync = payload.tools.find((tool) => tool.name === 'DesignSync');
  assert.ok(designSync, 'DesignSync parity map entry');
  assert.equal(designSync.mode, 'parity-only');
  assert.equal(designSync.implemented, true);
  assert.equal(designSync.passed, true);
  assert.equal(payload.parity_only, 1);
  assert.ok(payload.tools.filter((tool) => tool.mode === 'parity-only').every((tool) => tool.name === 'DesignSync'));
  for (const forbidden of ['std.net', 'std.fs', 'std.process', 'getEnv', 'http']) {
    assert.ok(!sourceText.includes(forbidden), 'parity source contains ' + forbidden);
  }
  assert.ok(!sourceText.includes('//'), 'parity source contains a comment');
  assert.ok(!sourceText.includes('/*'), 'parity source contains a comment');
  return { total: payload.total, implemented: payload.implemented, passed: payload.passed, parityOnly: payload.parity_only, excluded: payload.excluded_count };
}

export function runCheck() {
  const run = spawnSync(binary, ['parity', '4', '--json'], { cwd: repo, encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
  assert.equal(run.error, undefined, run.error ? String(run.error) : 'fx spawn failed');
  assert.equal(run.status, 0, 'fx parity 4 --json exited ' + run.status + ': ' + run.stderr);
  const payload = parsePayload(run.stdout);
  const counts = validate(payload, readFileSync(paritySourcePath, 'utf8'));
  console.log('item4 parity ok: ' + counts.total + ' tools implemented, ' + counts.passed + ' local happy paths passed, ' + counts.parityOnly + ' parity-only, ' + counts.excluded + ' isolation tools excluded');
  return counts;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) runCheck();
