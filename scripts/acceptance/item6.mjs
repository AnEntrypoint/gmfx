import { spawnSync, execFileSync } from 'node:child_process';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const repo = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const binary = resolve(repo, 'zig-out/bin/fx');

function check(condition, message) {
  if (!condition) throw new Error(message);
}

function git(...args) {
  return execFileSync('git', ['-C', repo, ...args], { encoding: 'utf8' }).trim();
}

function main() {
  const run = spawnSync(binary, ['parity', '6', '--json'], { cwd: repo, encoding: 'utf8' });
  check(!run.error, 'binary failed to start: ' + (run.error ? run.error.message : 'unknown'));
  check(run.status === 0, 'binary exited ' + run.status + ': ' + run.stderr);
  check(run.stderr.trim() === '', 'binary wrote stderr: ' + run.stderr);

  let report;
  try {
    report = JSON.parse(run.stdout);
  } catch {
    throw new Error('binary did not print JSON: ' + run.stdout);
  }

  const head = git('rev-parse', 'HEAD');
  const tree = git('rev-parse', 'HEAD^{tree}');
  const branch = git('symbolic-ref', '--short', 'HEAD');
  const status = git('status', '--porcelain');
  const receiptPrefix = 'item6:' + head + ':' + tree + ':' + branch + ':lanmower:PASS:';

  check(report.item === 6, 'item is not 6: ' + report.item);
  check(report.ok === true, 'report ok is not true: ' + report.ok);
  check(report.status === 'verified', 'status is not verified: ' + report.status);
  check(report.head === head, 'head mismatch: ' + report.head);
  check(report.tree === tree, 'tree mismatch: ' + report.tree);
  check(report.branch === 'main' && branch === 'main', 'branch is not main: ' + report.branch);
  check(report.clean_tree === (status.length === 0), 'clean_tree mismatch: ' + report.clean_tree);
  check(report.author === 'lanmower', 'author is not lanmower: ' + report.author);
  check(report.authors_ok === true, 'authors_ok is not true: ' + report.authors_ok);
  check(report.base_head === 'f1902e7086d27cbe136e76ba55313d250d68195f', 'base head mismatch: ' + report.base_head);
  check(report.new_commits === 0 || report.head_author === 'lanmower', 'new commits are not lanmower-only: ' + report.head_author);
  check(Array.isArray(report.trailers) && report.trailers.length === 0, 'trailers are not empty');
  check(report.trailer_count === 0 && report.trailers_ok === true, 'forbidden trailers found: ' + report.trailer_count);
  check(typeof report.receipt === 'string' && report.receipt.startsWith(receiptPrefix), 'receipt missing evidence: ' + report.receipt);
  check(Array.isArray(report.ci_shape_scripts) && report.ci_shape_scripts.length >= 10, 'ci shape scripts missing');
  check(report.ci_shape_scripts.every((entry) => entry.present === true), 'ci shape script missing on disk');
  check(report.ci_shape_ok === true, 'ci_shape_ok is not true');
  check(report.binary_marker === 'PASS', 'binary marker is not PASS: ' + report.binary_marker);
  check(typeof report.witness === 'string' && report.witness.includes(head) && report.witness.includes(report.receipt), 'witness missing receipt: ' + report.witness);

  console.log('item6 PASS head=' + head + ' author=' + report.author + ' trailers=' + report.trailer_count + ' receipt=' + report.receipt + ' marker=' + report.binary_marker);
}

try {
  main();
} catch (error) {
  console.error('item6 FAIL: ' + error.message);
  process.exitCode = 1;
}
