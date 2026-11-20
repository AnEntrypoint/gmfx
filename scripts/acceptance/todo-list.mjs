import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { listing, providerSettings, rejection, startStub, toolContents } from './todo-stub.mjs';

const run = promisify(execFile);
const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '..', '..');
const binary = process.env.FX_TODO_BINARY || path.join(repo, 'zig-out', 'bin', 'fx');
const toolName = process.env.FX_TODO_TOOL_NAME || 'TodoList';
assert.ok(fs.existsSync(binary), 'build the binary first: zig build');

const work = fs.mkdtempSync(path.join(os.tmpdir(), 'fx-todo-list-'));
const home = path.join(work, 'home');
fs.mkdirSync(path.join(home, '.fx'), { recursive: true });
const stub = await startStub(toolName);

async function ask(args, prompt) {
  fs.writeFileSync(path.join(home, '.fx', 'settings.json'), JSON.stringify(providerSettings(stub.port)));
  const before = stub.requests.length;
  let status = 0;
  let stderr = '';
  try {
    const result = await run(binary, ['ask', '--provider', 'stub', '--model', 'stub-model', ...args, '--', prompt], {
      cwd: work,
      env: { ...process.env, HOME: home },
      timeout: 120000,
      maxBuffer: 16 * 1024 * 1024,
    });
    stderr = result.stderr;
  } catch (error) {
    status = error.code;
    stderr = error.stderr || '';
  }
  return { status, stderr, requests: stub.requests.slice(before) };
}

try {
  const cycle = await ask(['--no-save'], '[todo-cycle] plan the work');
  assert.equal(cycle.status, 0, `cycle: fx exited ${cycle.status}: ${cycle.stderr}`);
  assert.ok(cycle.requests.length > 0, 'cycle: fx sent no request to the stub');
  const cycleTools = toolContents(cycle.requests.at(-1));
  assert.equal(cycleTools.length, 3, `cycle: expected 3 tool results, got ${cycleTools.length}`);
  const [written, read, rejected] = cycleTools;
  assert.ok(written.startsWith('Todo list updated.\n' + listing + '\n\n'), `write: wrong result: ${written}`);
  assert.ok(written.includes('When "Read AGENTS.md" is finished'), 'write: next-step hint missing');
  assert.equal(read, listing, 'read: same-turn read must return the written list');
  assert.equal(rejected, rejection, 'reject: invalid status must fail with the schema message');

  const saved = await ask([], '[todo-write] save the plan');
  assert.equal(saved.status, 0, `save: fx exited ${saved.status}: ${saved.stderr}`);
  assert.equal(toolContents(saved.requests.at(-1)).at(-1), 'Todo list updated.\n' + listing + '\n\nWhen "Read AGENTS.md" is finished, mark it done and set the next item in_progress; that update can go in the same response as your next tool call.', 'save: wrong write result');

  const resumed = await ask(['--resume', 'last'], '[todo-read] show the plan');
  assert.equal(resumed.status, 0, `resume: fx exited ${resumed.status}: ${resumed.stderr}`);
  assert.equal(toolContents(resumed.requests.at(-1)).at(-1), listing, 'resume: list must be derived from the saved session history');

  const everything = JSON.stringify(stub.requests);
  assert.equal(everything.includes(`Unsupported tool: ${toolName}`), false, `baseline: ${toolName} is still unsupported`);

  console.log('todo-list gate: write, same-turn read, rejection, and cross-turn history witnesses passed');
} finally {
  await stub.close();
  fs.rmSync(work, { recursive: true, force: true });
}
