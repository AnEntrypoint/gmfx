import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const repo = resolve(here, '..', '..');
const artifact = JSON.parse(readFileSync(join(here, 'environment-inventory.json'), 'utf8'));

assert.equal(artifact.item, 'environment-inventory', 'artifact item differs');
assert.equal(artifact.counts.hostTools, artifact.hostTools.length, 'host tool count differs from list');
assert.equal(artifact.counts.gmVerbs, artifact.gmVerbs.length, 'gm verb count differs from list');
assert.equal(artifact.counts.total, 76, 'total inventory is not 76');
assert.equal(artifact.counts.total, artifact.hostTools.length + artifact.gmVerbs.length, 'total differs from lists');
for (const [label, names] of [['hostTools', artifact.hostTools], ['gmVerbs', artifact.gmVerbs]]) {
  assert.equal(new Set(names).size, names.length, label + ' has duplicate names');
  assert.ok(names.every((name) => typeof name === 'string' && name.length > 0), label + ' has an empty name');
}

const sourcePath = join(repo, '..', 'work', 'inventory-host-tools.json');
let sourceWitness = 'source absent';
if (existsSync(sourcePath)) {
  const digest = createHash('sha256').update(readFileSync(sourcePath)).digest('hex');
  assert.equal(digest, artifact.source.sha256, 'source inventory changed since the artifact was written');
  sourceWitness = 'sha256 matches';
}

console.log(JSON.stringify({ item: 'environment-inventory', mode: 'static', counts: artifact.counts, source: sourceWitness, ok: true, status: 'implemented' }));
