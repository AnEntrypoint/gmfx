import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { lastUserPrompt, listing, providerSettings, startStub, toolContents } from './todo-stub.mjs';

const run = promisify(execFile);
const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '..', '..');
const binary = process.env.FX_TODO_BINARY || path.join(repo, 'zig-out', 'bin', 'fx');
const tmuxSocket = 'fx-todo-subagent-gate';
assert.ok(fs.existsSync(binary), 'build the binary first: zig build');

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const tmux = (args) => run('tmux', ['-L', tmuxSocket, ...args]).then((r) => r.stdout, (e) => e.stdout || '');

const work = fs.mkdtempSync(path.join(os.tmpdir(), 'fx-todo-sub-'));
const home = path.join(work, 'home');
fs.mkdirSync(path.join(home, '.fx'), { recursive: true });
const stub = await startStub('TodoList');
fs.writeFileSync(path.join(home, '.fx', 'settings.json'), JSON.stringify(providerSettings(stub.port)));

const name = `todo-sub-${process.pid}`;
const stderrPath = path.join(work, 'fx.stderr');
try {
  await run('tmux', ['-L', tmuxSocket, 'new-session', '-d', '-s', name, '-x', '200', '-y', '50', `HOME=${home} KIMI_CODE_TRUST_WORKSPACE=1 ${binary} 2>${stderrPath}`]);
  await sleep(8000);
  await tmux(['send-keys', '-t', name, 'Escape']);
  await sleep(2000);
  await tmux(['send-keys', '-t', name, '[todo-sub] delegate the planning', 'Enter']);

  const deadline = Date.now() + 90000;
  let child = [];
  while (Date.now() < deadline) {
    child = stub.requests.filter((body) => lastUserPrompt(body.messages || []).includes('[todo-child]'));
    if (child.length > 0 && toolContents(child.at(-1)).length > 0) break;
    await sleep(500);
  }
  assert.ok(child.length > 0, 'subagent: the child never ran a turn');
  const childTools = toolContents(child.at(-1));
  assert.ok(childTools.length > 0, 'subagent: the child made no tool call');
  assert.ok(childTools.at(0).startsWith('Todo list updated.\n' + listing + '\n\n'), `subagent: child TodoList result wrong: ${childTools.at(0)}`);

  const everything = JSON.stringify(stub.requests);
  assert.equal(everything.includes('TodoList is not available in this session.'), false, 'subagent: TodoList is not wired into the child context');
  assert.equal(everything.includes('Unsupported tool: TodoList'), false, 'baseline: TodoList is still unsupported in subagents');

  console.log('todo-subagent gate: child TodoList write witnessed through the subagent context');
} finally {
  await tmux(['kill-session', '-t', name]);
  await tmux(['kill-server']);
  await stub.close();
  fs.rmSync(work, { recursive: true, force: true });
}
