import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '..', '..');
const binary = path.join(repo, 'zig-out', 'bin', 'fx');
const fixtureHome = process.env.FX_EXPORT_HOME;
const sessionId = process.env.FX_EXPORT_SESSION;
const tmuxSocket = 'fx-export-md-gate';

assert.ok(fixtureHome && sessionId, 'set FX_EXPORT_HOME (a HOME holding .fx/sessions) and FX_EXPORT_SESSION (a saved session id in it)');
assert.ok(fs.existsSync(binary), 'build the binary first: zig build');

const work = fs.mkdtempSync(path.join(os.tmpdir(), 'fx-export-md-'));
const home = path.join(work, 'home');
fs.cpSync(path.join(fixtureHome, '.fx'), path.join(home, '.fx'), { recursive: true });

function tmux(args) {
  return spawnSync('tmux', ['-L', tmuxSocket, ...args], { encoding: 'utf8' });
}

function sleep(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

function drive(command, expected) {
  const name = `gate-${process.pid}-${Math.random().toString(36).slice(2, 8)}`;
  const stderrPath = path.join(work, `${name}.stderr`);
  const launch = `HOME=${home} KIMI_CODE_TRUST_WORKSPACE=1 ${binary} -r ${sessionId} 2>${stderrPath}`;
  const started = tmux(['new-session', '-d', '-s', name, '-x', '200', '-y', '50', launch]);
  assert.equal(started.status, 0, 'tmux could not start fx: ' + started.stderr);
  try {
    sleep(8000);
    tmux(['send-keys', '-t', name, 'Escape']);
    sleep(2000);
    tmux(['send-keys', '-t', name, command, 'Enter']);
    let pane = '';
    const deadline = Date.now() + 30000;
    while (Date.now() < deadline) {
      pane = tmux(['capture-pane', '-p', '-t', name]).stdout;
      if (expected.test(pane)) break;
      sleep(500);
    }
    const stderr = fs.existsSync(stderrPath) ? fs.readFileSync(stderrPath, 'utf8') : '';
    return { pane, stderr };
  } finally {
    tmux(['kill-session', '-t', name]);
  }
}

const okPath = path.join(work, 'ok.md');
const positive = drive(`/export-md ${okPath}`, /export: Exported \d+ turns to /);
assert.match(positive.pane, new RegExp(`Exported \\d+ turns to ${okPath.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}`), 'positive: success notice missing');
assert.equal(positive.stderr, '', 'positive: fx wrote stderr');
assert.ok(fs.existsSync(okPath), 'positive: export file was not written');
const markdown = fs.readFileSync(okPath, 'utf8');
assert.ok(markdown.startsWith(`---\nsession_id: ${sessionId}\n`), 'positive: frontmatter session_id missing');
assert.ok(markdown.includes('\n# fx Session Export\n'), 'positive: title missing');
assert.ok(markdown.includes('\n## Overview\n'), 'positive: overview missing');
assert.ok(markdown.includes('\n## Turn 1\n'), 'positive: first turn missing');
assert.ok(markdown.includes('\n#### Tool Call: '), 'positive: tool-call block missing');
assert.ok(markdown.includes('<details><summary>Tool Result: '), 'positive: tool-result block missing');

const dirAsFile = drive('/export-md /dev/null/x.md', /export: Failed to write/);
assert.match(dirAsFile.pane, /Failed to write \/dev\/null\/x\.md: NotDir/, 'negative: NotDir notice missing');
assert.equal(fs.existsSync('/dev/null/x.md'), false, 'negative: a file appeared under /dev/null');
assert.equal(dirAsFile.stderr, '', 'negative: fx wrote stderr');

const missingParent = drive('/export-md /proc/nope/x.md', /export: Failed to write/);
assert.match(missingParent.pane, /Failed to write \/proc\/nope\/x\.md: FileNotFound/, 'negative: missing-parent notice missing');
assert.equal(missingParent.stderr, '', 'negative: fx wrote stderr on missing parent');

fs.rmSync(work, { recursive: true, force: true });
console.log('export-md gate: positive and negative witnesses passed');
