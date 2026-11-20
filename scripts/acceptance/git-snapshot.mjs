import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '..', '..');
const binary = path.join(repo, 'zig-out', 'bin', 'fx');
const keys = ['command', 'ok', 'read_only', 'offline', 'error', 'in_git_repo', 'branch', 'head', 'clean', 'changes', 'recent_commits', 'staged_stat', 'unstaged_stat'];

function git(cwd, args) {
  const result = spawnSync('git', args, { cwd, encoding: 'utf8' });
  return { status: result.status, out: (result.stdout || '').replace(/\s+$/, '') };
}

function runSnapshot(cwd) {
  const result = spawnSync(binary, ['git-snapshot', '--json'], { cwd, encoding: 'utf8', timeout: 30000 });
  assert.equal(result.stderr, '', 'git-snapshot wrote stderr');
  return { status: result.status, report: JSON.parse(result.stdout) };
}

const real = runSnapshot(repo);
assert.equal(real.status, 0, 'real-tree git-snapshot exited ' + real.status);
assert.deepEqual(Object.keys(real.report), keys, 'real-tree schema keys differ');
assert.equal(real.report.command, 'git-snapshot');
assert.equal(real.report.ok, true);
assert.equal(real.report.read_only, true);
assert.equal(real.report.offline, true);
assert.equal(real.report.error, '');
assert.equal(real.report.in_git_repo, true);
assert.equal(real.report.branch, git(repo, ['branch', '--show-current']).out);
assert.equal(real.report.head, git(repo, ['rev-parse', 'HEAD']).out);
const porcelain = git(repo, ['status', '--short']).out.split('\n').filter((line) => line.length > 0);
assert.deepEqual(real.report.changes, porcelain, 'changes differ from git status --short');
assert.equal(real.report.clean, porcelain.length === 0);
const log = git(repo, ['log', '--oneline', '-5']).out.split('\n').filter((line) => line.length > 0);
assert.deepEqual(real.report.recent_commits, log, 'recent commits differ from git log');
assert.equal(real.report.staged_stat, git(repo, ['diff', '--stat', '--cached']).out.trim());
assert.equal(real.report.unstaged_stat, git(repo, ['diff', '--stat']).out.trim());

const outside = fs.mkdtempSync(path.join(os.tmpdir(), 'git-snapshot-negative-'));
const probe = git(outside, ['rev-parse', '--is-inside-work-tree']);
assert.notEqual(probe.status, 0, 'negative directory is inside a git repository');
const negative = runSnapshot(outside);
assert.equal(negative.status, 1, 'non-repo git-snapshot exited ' + negative.status);
assert.deepEqual(Object.keys(negative.report), keys, 'non-repo schema keys differ');
assert.equal(negative.report.ok, false);
assert.equal(negative.report.error, 'not_a_git_repository');
assert.equal(negative.report.in_git_repo, false);
assert.equal(negative.report.branch, '');
assert.equal(negative.report.head, '');
assert.deepEqual(negative.report.changes, []);
assert.equal(negative.report.clean, false, 'outside a repository must not report clean');
fs.rmSync(outside, { recursive: true, force: true });

console.log(JSON.stringify({ item: 'git-snapshot', mode: 'binary', real_tree: { branch: real.report.branch, changes: real.report.changes.length, recent_commits: real.report.recent_commits.length }, negative: negative.report.error, ok: true, status: 'implemented' }));
