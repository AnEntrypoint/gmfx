#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const TARGET = join(root, 'native', 'third_party', 'txiki');
const pinFlag = process.argv.indexOf('--pin');
if (pinFlag !== -1 && !process.argv[pinFlag + 1]) throw new Error('--pin needs a path to a pin file');
const pinPath = pinFlag === -1 ? join(root, 'scripts', 'txiki', 'pin.json') : resolve(process.argv[pinFlag + 1]);
const pins = JSON.parse(readFileSync(pinPath, 'utf8'));
const TXIKI_VERSION = { major: '26', minor: '11', patch: '0', suffix: '' };
const TXIKI_SOURCES = [
  'vm.c', 'timers.c', 'utils.c', 'modules.c', 'error.c', 'mem.c', 'text-coding.c', 'tbuf.c', 'builtins.c', 'signals.c',
  'mod_os.c', 'mod_sys.c', 'mod_fs.c', 'mod_streams.c', 'worker.c', 'eval.c', 'url.c', 'mod_engine.c', 'version.c',
  'mod_channel.c', 'mod_dns.c', 'mod_fswatch.c', 'mod_process.c', 'mod_udp.c', 'mod_posix-socket.c',
];
const TXIKI_HEADERS_SKIPPED = new Set(['cacert.h', 'ed25519.h', 'mbedtls_config.h', 'wasm.h']);
const TXIKI_BUNDLES = [
  'core/core.c', 'core/polyfills.c', 'core/run-main.c', 'core/worker-bootstrap.c', 'internal/home.c', 'internal/path.c',
  'stdlib/assert.c', 'stdlib/getopts.c', 'stdlib/hashing.c', 'stdlib/ipaddr.c', 'stdlib/path.c', 'stdlib/posix-socket.c',
  'stdlib/readline.c', 'stdlib/utils.c', 'stdlib/uuid.c',
];
const ADA_FILES = ['ada.cpp', 'ada.h', 'ada_c.h'];
const LIBUV_BUILD_FILES = new Set(['CMakeLists.txt', 'configure.ac', 'libuv.pc.in', 'libuv-static.pc.in']);
const QUICKJS_SOURCES = ['quickjs.c', 'dtoa.c', 'libregexp.c', 'libunicode.c'];
const QUICKJS_HEADERS_SKIPPED = new Set(['quickjs-libc.h']);
const LICENSE_NAME = /^(LICENSE|LICENSE-.*|COPYING)(\.txt|\.md)?$/i;

const sha256Of = (path) => createHash('sha256').update(readFileSync(path)).digest('hex');

const run = (command, args) => {
  const result = spawnSync(command, args, { encoding: 'utf8', timeout: 900000 });
  if (result.status !== 0) throw new Error(command + ' ' + args.join(' ') + ' failed: ' + (result.error?.message ?? result.stderr));
};

const listFiles = (dir, prefix = '') => readdirSync(join(dir, prefix), { withFileTypes: true }).flatMap((entry) => {
  const relative = prefix ? prefix + '/' + entry.name : entry.name;
  return entry.isDirectory() ? listFiles(dir, relative) : [relative];
});

const copyWhere = (from, to, keep) => {
  let count = 0;
  for (const relative of listFiles(from)) {
    if (!keep(relative)) continue;
    mkdirSync(dirname(join(to, relative)), { recursive: true });
    cpSync(join(from, relative), join(to, relative));
    count += 1;
  }
  return count;
};

const work = mkdtempSync(join(tmpdir(), 'fx-txiki-'));
try {
  const trees = {};
  for (const name of ['txiki', 'libuv', 'quickjs']) {
    const pin = pins[name];
    const archive = join(work, name + '.tar.gz');
    run('curl', ['-sSL', '--fail', '--max-time', '900', '-o', archive, pin.url]);
    const digest = sha256Of(archive);
    if (digest !== pin.sha256) throw new Error(pin.url + ' sha256 ' + digest + ' does not match the pin ' + pin.sha256);
    trees[name] = join(work, name);
    mkdirSync(trees[name]);
    run('tar', ['-xzf', archive, '-C', trees[name], '--strip-components=1']);
  }

  rmSync(TARGET, { recursive: true, force: true });
  const txikiSrc = join(trees.txiki, 'src');
  let files = 0;
  files += copyWhere(txikiSrc, join(TARGET, 'txiki', 'src'), (r) => !r.includes('/') && ((r.endsWith('.h') && !TXIKI_HEADERS_SKIPPED.has(r)) || TXIKI_SOURCES.includes(r)));
  files += copyWhere(join(txikiSrc, 'bundles', 'c'), join(TARGET, 'txiki', 'src', 'bundles', 'c'), (r) => TXIKI_BUNDLES.includes(r));
  files += copyWhere(join(trees.txiki, 'deps', 'ada'), join(TARGET, 'txiki', 'deps', 'ada'), (r) => ADA_FILES.includes(r) || LICENSE_NAME.test(r));
  files += copyWhere(trees.txiki, join(TARGET, 'txiki'), (r) => r === 'LICENSE');
  const versionHeader = readFileSync(join(txikiSrc, 'version.h.in'), 'utf8')
    .replace('@TJS__VERSION_MAJOR@', TXIKI_VERSION.major)
    .replace('@TJS__VERSION_MINOR@', TXIKI_VERSION.minor)
    .replace('@TJS__VERSION_PATCH@', TXIKI_VERSION.patch)
    .replace('@TJS__VERSION_SUFFIX@', TXIKI_VERSION.suffix);
  if (/@TJS__\w+@/.test(versionHeader)) throw new Error('version.h.in has a placeholder this script does not fill');
  writeFileSync(join(TARGET, 'txiki', 'src', 'version.h'), versionHeader);
  files += 1;
  files += copyWhere(trees.libuv, join(TARGET, 'libuv'), (r) => r.startsWith('include/') || r.startsWith('src/') || (!r.includes('/') && (LICENSE_NAME.test(r) || LIBUV_BUILD_FILES.has(r))));
  files += copyWhere(trees.quickjs, join(TARGET, 'quickjs'), (r) => !r.includes('/') && (QUICKJS_SOURCES.includes(r) || (r.endsWith('.h') && !QUICKJS_HEADERS_SKIPPED.has(r)) || LICENSE_NAME.test(r)));

  for (const source of TXIKI_SOURCES) if (!existsSync(join(TARGET, 'txiki', 'src', source))) throw new Error('the txiki archive has no src/' + source);
  for (const bundle of TXIKI_BUNDLES) if (!existsSync(join(TARGET, 'txiki', 'src', 'bundles', 'c', bundle))) throw new Error('the txiki archive has no bundle ' + bundle);
  for (const source of QUICKJS_SOURCES) if (!existsSync(join(TARGET, 'quickjs', source))) throw new Error('the quickjs-ng archive has no ' + source);

  const lines = ['fx vendored txiki.js runtime core', ''];
  for (const name of ['txiki', 'libuv', 'quickjs']) lines.push(pins[name].label + ' from ' + pins[name].url + ' sha256 ' + pins[name].sha256);
  lines.push('', 'Only the runtime core is copied. The network modules (http, ws, tls, webcrypto, hashing, wasm, ffi, sqlite, miniz) are stubbed in native/txiki/glue/txiki_stubs.c.', '');
  writeFileSync(join(TARGET, 'VERSION.txt'), lines.join('\n'));
  console.log('vendor-txiki: wrote ' + files + ' files under native/third_party/txiki; pins ' + ['txiki', 'libuv', 'quickjs'].map((n) => n + ' ' + pins[n].sha256.slice(0, 12)).join(', '));
} finally {
  rmSync(work, { recursive: true, force: true });
}
