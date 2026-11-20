import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, '../..');
const stateDir = path.resolve(repoRoot, '../work/gm-parity');
const binary = path.join(repoRoot, 'zig-out/bin/fx');
const requestPath = path.join(stateDir, 'request.txt');
const eventsPath = path.join(stateDir, 'events.log');
const statePath = path.join(stateDir, 'state.txt');
const exactRefusal = 'finish refused while a PRD or question row is open: unknown:item2-attribution';
const quotedWitness = '"item 2 ledger: open rows 0, pending 0, jobs stopped 1, events 38"';
const keys = ['next_context', 'run_code', 'run_open', 'query_log', 'prd_add', 'unknown_add', 'prd_resolve', 'unknown_resolve', 'pending_event', 'pending_delivery', 'child_session', 'job_start', 'job_stop', 'finish'];
const openCounts = [1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
const addCounts = [2, 2, 1, 1, 1, 1, 0, 0, 2, 0, 0, 0, 0, 0];
const childCounts = [3, 3, 1, 1, 1, 1, 0, 0, 2, 2, 2, 0, 0, 0];
const jobCounts = [4, 4, 1, 2, 1, 1, 0, 0, 4, 4, 2, 1, 1, 0];
const resolveCounts = [5, 5, 1, 3, 1, 1, 1, 0, 4, 4, 2, 1, 1, 0];
const refusedCounts = [6, 6, 1, 4, 1, 1, 1, 0, 4, 4, 2, 1, 1, 1];
const acceptedCounts = [7, 7, 1, 5, 1, 1, 1, 1, 4, 4, 2, 1, 1, 2];
const prdRow = { id: 'prd:item2-ledger', kind: 'prd', status: 'open' };
const unknownRow = { id: 'unknown:item2-attribution', kind: 'unknown', status: 'open' };
const bothRows = [prdRow, unknownRow];
const unknownRows = [unknownRow];
const childSessions = [
  { kind: 'subagent', run: 'item2-local-run', role: 'child' },
  { kind: 'separate', run: 'item2-child-run', role: 'owner' },
];
const stoppedJob = [{ id: 'ledger-job', state: 'stopped' }];
const pendingTwo = ['pending:1', 'pending:2'];
const phases = [
  { request: { phase: 'open' }, expected: openCounts, step: 1, ok: true, rows: [], pending: [], children: [], jobs: [], finished: false, witness: '', refusal: '' },
  { request: { phase: 'add' }, expected: addCounts, step: 2, ok: true, rows: bothRows, pending: pendingTwo, children: [], jobs: [], finished: false, witness: '', refusal: '' },
  { request: { phase: 'child' }, expected: childCounts, step: 3, ok: true, rows: bothRows, pending: [], children: childSessions, jobs: [], finished: false, witness: '', refusal: '' },
  { request: { phase: 'job' }, expected: jobCounts, step: 4, ok: true, rows: bothRows, pending: [], children: childSessions, jobs: stoppedJob, finished: false, witness: '', refusal: '' },
  { request: { phase: 'resolve', row: 'prd' }, expected: resolveCounts, step: 5, ok: true, rows: unknownRows, pending: [], children: childSessions, jobs: stoppedJob, finished: false, witness: '', refusal: '' },
  { request: { phase: 'finish-refused', witness: quotedWitness }, expected: refusedCounts, step: 6, ok: false, rows: unknownRows, pending: [], children: childSessions, jobs: stoppedJob, finished: false, witness: '', refusal: exactRefusal },
  { request: { phase: 'finish-accepted', row: 'unknown', witness: quotedWitness }, expected: acceptedCounts, step: 7, ok: true, rows: [], pending: [], children: childSessions, jobs: stoppedJob, finished: true, witness: quotedWitness, refusal: '' },
];

function countsFrom(values) {
  return Object.fromEntries(keys.map((key, index) => [key, values[index]]));
}

function sum(values) {
  return values.reduce((total, value) => total + value, 0);
}

function requestText(request) {
  return Object.entries(request).map(([key, value]) => key + '=' + value).join('\n') + '\n';
}

function countLines(lines) {
  const result = Object.fromEntries(keys.map((key) => [key, 0]));
  for (const line of lines) {
    if (Object.prototype.hasOwnProperty.call(result, line)) result[line] += 1;
  }
  return result;
}

function runPhase(phase) {
  fs.writeFileSync(requestPath, requestText(phase.request));
  const result = spawnSync(binary, ['parity', '2', '--json'], { cwd: repoRoot, encoding: 'utf8', maxBuffer: 4 * 1024 * 1024 });
  assert.equal(result.status, 0, 'fx parity 2 --json failed: ' + (result.error ? result.error.message : result.stderr));
  const lines = result.stdout.trim().split('\n').map((line) => line.trim()).filter(Boolean);
  assert.ok(lines.length > 0, 'fx parity 2 --json printed no JSON');
  return JSON.parse(lines[lines.length - 1]);
}

try {
  fs.rmSync(stateDir, { recursive: true, force: true });
  fs.mkdirSync(stateDir, { recursive: true });
  const results = [];
  for (const phase of phases) {
    const payload = runPhase(phase);
    assert.equal(payload.item, 2);
    assert.equal(payload.run, 'item2-local-run');
    assert.equal(payload.phase, phase.request.phase);
    assert.equal(payload.step, phase.step);
    assert.equal(payload.ok, phase.ok);
    assert.equal(payload.eventCount, sum(phase.expected));
    assert.deepEqual(payload.counts, countsFrom(phase.expected));
    assert.deepEqual(payload.rows, phase.rows);
    assert.deepEqual(payload.pending, phase.pending);
    assert.deepEqual(payload.children, phase.children);
    assert.deepEqual(payload.jobs, phase.jobs);
    assert.equal(payload.finished, phase.finished);
    assert.equal(payload.witness, phase.witness);
    assert.equal(payload.refusal, phase.refusal);
    results.push(payload);
  }
  assert.equal(results[5].refusal, exactRefusal);
  assert.equal(results[6].witness, quotedWitness);
  const eventLines = fs.readFileSync(eventsPath, 'utf8').trim().split('\n').filter(Boolean);
  assert.equal(eventLines.length, 38);
  assert.deepEqual(countLines(eventLines), countsFrom(acceptedCounts));
  const ledgerState = fs.readFileSync(statePath, 'utf8');
  assert.match(ledgerState, /finished=1/);
  assert.ok(ledgerState.includes('witness=' + quotedWitness));
  console.log(JSON.stringify({ item: 2, ok: true, phases: results.map((result) => result.phase), events: eventLines.length, refusal: exactRefusal, witness: quotedWitness }));
} catch (error) {
  console.error(error);
  process.exitCode = 1;
}
