import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '..', '..');
const binary = path.join(repo, 'zig-out', 'bin', 'fx');
const workRoot = '/workspace/fx/work/acceptance';
fs.mkdirSync(workRoot, { recursive: true });

function fixture(withSurface) {
  const root = fs.mkdtempSync(path.join(workRoot, 'item7-'));
  if (withSurface) {
    fs.mkdirSync(path.join(root, 'mcp'), { recursive: true });
    fs.mkdirSync(path.join(root, 'skills', 'gm'), { recursive: true });
    fs.writeFileSync(path.join(root, 'mcp', 'server.json'), JSON.stringify({
      name: 'gm',
      instructions: 'Use gm MCP tools and the gm skill for every repository read or write.',
      resources: [{ uri: 'run://local/log' }, { uri: 'skill://gm/SKILL.md' }]
    }, null, 2) + '\n');
    fs.writeFileSync(path.join(root, 'skills', 'gm', 'SKILL.md'), '# gm loop\n\nStart every step with next_context.\n');
    fs.writeFileSync(path.join(root, 'skills', 'gm', 'witness'), 'witness\n');
  }
  return root;
}

function runParity(root) {
  const result = spawnSync(path.join(binary), ['parity', '7', '--json'], {
    cwd: repo,
    encoding: 'utf8',
    env: { FX_PARITY_CONTEXT_ROOT: root, HOME: root, PATH: '/usr/bin:/bin' },
    timeout: 30000
  });
  assert.equal(result.status, 0, 'parity 7 exited ' + result.status + ': ' + result.stderr);
  assert.equal(result.stderr, '', 'parity 7 wrote stderr');
  return JSON.parse(result.stdout);
}

const source = fs.readFileSync(path.join(repo, 'src', 'core', 'parity', 'item7.zig'), 'utf8');
for (const token of ['ListMcpResourcesTool', 'ReadMcpResourceTool', 'ReadMcpResourceDirTool', 'MCP server instructions', 'mcp/server.json']) {
  assert.ok(source.includes(token), 'missing token ' + token);
}

const observed = runParity(fixture(true));
assert.equal(observed.item, 7, 'item is not 7');
assert.equal(observed.kind, 'mcp-resources', 'kind differs');
assert.equal(observed.offline, true, 'offline flag missing');
assert.equal(observed.status, 'implemented', 'observed status is not implemented');
assert.equal(observed.ok, true, 'observed ok is not true');
assert.deepEqual(observed.resources, ['run://local/log', 'skill://gm/SKILL.md'], 'resources differ');
assert.equal(observed.mcp_server_instructions, 'Use gm MCP tools and the gm skill for every repository read or write.');
assert.deepEqual(observed.entries.map((entry) => entry.name), ['ListMcpResourcesTool', 'ReadMcpResourceTool', 'ReadMcpResourceDirTool', 'MCP server instructions']);
assert.ok(observed.entries.every((entry) => entry.passed === true), 'an observed entry failed');

const absent = runParity(fixture(false));
assert.equal(absent.item, 7, 'absent item is not 7');
assert.equal(absent.status, 'open', 'absent status is not open');
assert.equal(absent.ok, false, 'absent ok must be false');
assert.ok(absent.entries.every((entry) => entry.passed === false && entry.detail.length > 0), 'absent entries must be recorded as open with detail');

console.log(JSON.stringify({ item: 7, mode: 'binary', observed: observed.entries.length, absent_open: absent.entries.length, ok: true, status: 'implemented' }));
