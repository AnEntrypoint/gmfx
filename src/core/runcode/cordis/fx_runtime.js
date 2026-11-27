const ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

const coded = (code, message) => {
  const error = new Error(message)
  error.code = code
  return error
}

const fail = (name) => function unsupportedFunction() {
  throw coded('ERR_FX_UNSUPPORTED', name + ' is not available in fx: the embedded runtime does not provide it')
}

const host = (name, args) => {
  const reply = globalThis.gm[name](args ?? {})
  if (reply === null || typeof reply !== 'object') throw coded('EFXHOST', 'fx host verb ' + name + ' returned no reply')
  if (reply.ok === false) throw coded(reply.code ?? 'EFXHOST', reply.error ?? name + ' failed')
  return reply
}

let processState = null
const processInfo = () => {
  if (processState === null) processState = host('process_info', {})
  return processState
}

const encodeBase64 = (bytes) => {
  let out = ''
  for (let i = 0; i < bytes.length; i += 3) {
    const a = bytes[i]
    const b = i + 1 < bytes.length ? bytes[i + 1] : 0
    const c = i + 2 < bytes.length ? bytes[i + 2] : 0
    const triple = (a << 16) | (b << 8) | c
    out += ALPHABET[(triple >> 18) & 63] + ALPHABET[(triple >> 12) & 63]
    out += i + 1 < bytes.length ? ALPHABET[(triple >> 6) & 63] : '='
    out += i + 2 < bytes.length ? ALPHABET[triple & 63] : '='
  }
  return out
}

const decodeBase64 = (text) => {
  const clean = text.replace(/=+$/, '')
  const bytes = new Uint8Array(Math.floor((clean.length * 3) / 4))
  let buffer = 0
  let bits = 0
  let index = 0
  for (let i = 0; i < clean.length; i += 1) {
    buffer = ((buffer << 6) | ALPHABET.indexOf(clean[i])) & 0xffffff
    bits += 6
    if (bits >= 8) {
      bits -= 8
      bytes[index] = (buffer >> bits) & 0xff
      index += 1
    }
  }
  return bytes
}

const encodeHex = (bytes) => Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0')).join('')

const decodeHex = (text) => Uint8Array.from(text.match(/../g) ?? [], (pair) => parseInt(pair, 16))

const encodeUtf8 = (text) => {
  const out = []
  for (const character of text) {
    const code = character.codePointAt(0)
    if (code < 0x80) out.push(code)
    else if (code < 0x800) out.push(0xc0 | (code >> 6), 0x80 | (code & 63))
    else if (code < 0x10000) out.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 63), 0x80 | (code & 63))
    else out.push(0xf0 | (code >> 18), 0x80 | ((code >> 12) & 63), 0x80 | ((code >> 6) & 63), 0x80 | (code & 63))
  }
  return Uint8Array.from(out)
}

const decodeUtf8 = (bytes) => {
  let out = ''
  let i = 0
  while (i < bytes.length) {
    const lead = bytes[i]
    let code = 0xfffd
    let extra = 0
    if (lead < 0x80) code = lead
    else if (lead >= 0xf0) { code = lead & 7; extra = 3 }
    else if (lead >= 0xe0) { code = lead & 15; extra = 2 }
    else if (lead >= 0xc0) { code = lead & 31; extra = 1 }
    i += 1
    for (let k = 0; k < extra && i < bytes.length; k += 1) {
      code = (code << 6) | (bytes[i] & 63)
      i += 1
    }
    out += String.fromCodePoint(code > 0x10ffff ? 0xfffd : code)
  }
  return out
}

const decodeLatin1 = (bytes) => Array.from(bytes, (byte) => String.fromCharCode(byte)).join('')

const toBytes = (data, encoding) => {
  if (typeof data === 'string') {
    if (encoding === 'base64') return decodeBase64(data)
    if (encoding === 'hex') return decodeHex(data)
    if (encoding === 'latin1' || encoding === 'binary') return Uint8Array.from(data, (character) => character.charCodeAt(0) & 0xff)
    return encodeUtf8(data)
  }
  if (data instanceof ArrayBuffer) return new Uint8Array(data)
  if (ArrayBuffer.isView(data)) return new Uint8Array(data.buffer, data.byteOffset, data.byteLength)
  throw new TypeError('the data must be a string or binary data')
}

const fromBytes = (bytes, encoding) => {
  if (encoding === undefined || encoding === null || encoding === 'buffer') return bytes
  if (encoding === 'base64') return encodeBase64(bytes)
  if (encoding === 'hex') return encodeHex(bytes)
  if (encoding === 'latin1' || encoding === 'binary') return decodeLatin1(bytes)
  return decodeUtf8(bytes)
}

const concatBytes = (parts) => {
  const out = new Uint8Array(parts.reduce((sum, part) => sum + part.length, 0))
  let offset = 0
  for (const part of parts) {
    out.set(part, offset)
    offset += part.length
  }
  return out
}

const encodingOf = (options) => (typeof options === 'string' ? options : options?.encoding ?? undefined)

const normalizeSegments = (path, allowAboveRoot) => {
  const segments = []
  for (const segment of path.split('/')) {
    if (segment === '' || segment === '.') continue
    if (segment !== '..') segments.push(segment)
    else if (segments.length > 0 && segments[segments.length - 1] !== '..') segments.pop()
    else if (allowAboveRoot) segments.push('..')
  }
  return segments.join('/')
}

const normalize = (path) => {
  if (path === '') return '.'
  const absolute = path.startsWith('/')
  const trailing = path.endsWith('/')
  let out = normalizeSegments(path, !absolute)
  if (out === '' && !absolute) out = '.'
  if (trailing && out !== '') out += '/'
  return (absolute ? '/' : '') + out
}

const join = (...parts) => {
  const joined = parts.filter((part) => part !== '').join('/')
  return joined === '' ? '.' : normalize(joined)
}

const resolve = (...parts) => {
  let resolved = ''
  let absolute = false
  for (let index = parts.length - 1; index >= -1 && !absolute; index -= 1) {
    const part = index >= 0 ? parts[index] : processInfo().cwd
    if (part === '') continue
    resolved = part + '/' + resolved
    absolute = part.startsWith('/')
  }
  const out = normalizeSegments(resolved, !absolute)
  if (absolute) return '/' + out
  return out === '' ? '.' : out
}

const relative = (from, to) => {
  const source = resolve(from).split('/').filter(Boolean)
  const target = resolve(to).split('/').filter(Boolean)
  let shared = 0
  while (shared < source.length && shared < target.length && source[shared] === target[shared]) shared += 1
  return [...source.slice(shared).map(() => '..'), ...target.slice(shared)].join('/')
}

const dirname = (value) => {
  const stripped = value.replace(/\/+$/, '')
  if (stripped === '') return value.startsWith('/') ? '/' : '.'
  const index = stripped.lastIndexOf('/')
  if (index === -1) return '.'
  const head = stripped.slice(0, index).replace(/\/+$/, '')
  return head === '' ? '/' : head
}

const basename = (value, suffix) => {
  const stripped = value.replace(/\/+$/, '')
  const base = stripped.slice(stripped.lastIndexOf('/') + 1)
  return suffix !== undefined && base !== suffix && base.endsWith(suffix) ? base.slice(0, -suffix.length) : base
}

const extname = (value) => {
  const base = basename(value)
  const index = base.lastIndexOf('.')
  return index <= 0 ? '' : base.slice(index)
}

const isAbsolute = (value) => value.startsWith('/')

const parse = (value) => {
  const base = basename(value)
  const ext = extname(value)
  return {
    root: isAbsolute(value) ? '/' : '',
    dir: value.includes('/') ? dirname(value) : '',
    base,
    ext,
    name: ext === '' ? base : base.slice(0, -ext.length),
  }
}

const format = (parts) => {
  const base = parts.base ?? (parts.name ?? '') + (parts.ext ?? '')
  const dir = parts.dir ?? parts.root
  if (dir === undefined || dir === '') return base
  return dir === parts.root ? dir + base : dir + '/' + base
}

const posixPath = { sep: '/', delimiter: ':', normalize, join, resolve, relative, dirname, basename, extname, isAbsolute, parse, format, toNamespacedPath: (value) => value }

const win32Path = new Proxy({ sep: '\\', delimiter: ';' }, {
  get: (target, key) => {
    if (typeof key === 'symbol') return undefined
    if (key in target) return target[key]
    return fail('path.win32.' + key)
  },
})

const path = { ...posixPath, posix: posixPath, win32: win32Path }

const pathOf = (value) => (typeof value === 'string' ? value : fileURLToPath(value))

const fileURLToPath = (value) => {
  const url = typeof value === 'string' ? new URL(value) : value
  if (url.protocol !== 'file:') throw coded('ERR_INVALID_URL_SCHEME', 'The URL must be of scheme file')
  return decodeURIComponent(url.pathname)
}

const pathToFileURL = (value) => new URL('file://' + path.resolve(value).split('/').map(encodeURIComponent).join('/'))

const url = { fileURLToPath, pathToFileURL, URL: globalThis.URL, URLSearchParams: globalThis.URLSearchParams }

const fds = new Map()
let nextFd = 3

const fdEntry = (fd) => {
  const entry = fds.get(fd)
  if (entry === undefined) throw coded('EBADF', 'EBADF: bad file descriptor')
  return entry
}

const targetOf = (value) => (typeof value === 'number' ? fdEntry(value).path : pathOf(value))

const statsFrom = (info) => ({
  size: info.size,
  mode: info.mode,
  mtimeMs: info.mtimeMs,
  mtime: new Date(info.mtimeMs),
  isFile: () => info.type === 'file',
  isDirectory: () => info.type === 'directory',
  isSymbolicLink: () => info.type === 'symlink',
})

const direntFrom = (entry) => ({
  name: entry.name,
  isFile: () => entry.type === 'file',
  isDirectory: () => entry.type === 'directory',
  isSymbolicLink: () => entry.type === 'symlink',
})

const existsSync = (value) => {
  try {
    return host('fs_exists', { path: targetOf(value) }).exists === true
  } catch {
    return false
  }
}

const statOf = (value, follow, options) => {
  try {
    return statsFrom(host('fs_stat', { path: targetOf(value), follow }))
  } catch (error) {
    if (options?.throwIfNoEntry === false && error.code === 'ENOENT') return undefined
    throw error
  }
}

const readFileSync = (value, options) => fromBytes(decodeBase64(host('fs_read', { path: targetOf(value) }).base64), encodingOf(options))

const writeFileSync = (value, data, options) => {
  const flag = typeof options === 'object' && options !== null ? options.flag : undefined
  host('fs_write', { path: targetOf(value), base64: encodeBase64(toBytes(data, encodingOf(options))), append: flag === 'a' })
}

const openSync = (value, flags = 'r') => {
  const target = pathOf(value)
  if (flags.startsWith('r')) host('fs_stat', { path: target, follow: true })
  else host('fs_write', { path: target, base64: '', append: flags.startsWith('a') })
  const fd = nextFd
  nextFd += 1
  fds.set(fd, { path: target, position: 0, append: flags.startsWith('a') })
  return fd
}

const closeSync = (fd) => {
  fdEntry(fd)
  fds.delete(fd)
}

const readSync = (fd, buffer, offsetOrOptions = 0, lengthArg, positionArg) => {
  let offset = offsetOrOptions
  let length = lengthArg
  let position = positionArg
  if (typeof offsetOrOptions === 'object' && offsetOrOptions !== null) {
    offset = offsetOrOptions.offset ?? 0
    length = offsetOrOptions.length
    position = offsetOrOptions.position
  }
  const entry = fdEntry(fd)
  const explicit = position !== null && position !== undefined
  const at = explicit ? position : entry.position
  const span = length ?? buffer.byteLength - offset
  const bytes = decodeBase64(host('fs_read_range', { path: entry.path, position: at, length: span }).base64)
  buffer.set(bytes, offset)
  if (!explicit) entry.position += bytes.length
  return bytes.length
}

const writeSync = (fd, data, ...rest) => {
  const entry = fdEntry(fd)
  let bytes
  let position
  if (typeof data === 'string') {
    bytes = toBytes(data, rest[1])
    position = rest[0]
  } else {
    const offset = rest[0] ?? 0
    const length = rest[1] ?? data.byteLength - offset
    bytes = toBytes(data).subarray(offset, offset + length)
    position = rest[2]
  }
  const explicit = position !== null && position !== undefined
  const at = explicit ? position : entry.append ? null : entry.position
  host('fs_write_at', { path: entry.path, position: at, base64: encodeBase64(bytes) })
  if (!explicit) entry.position += bytes.length
  return bytes.length
}

const fsConstants = { F_OK: 0, R_OK: 4, W_OK: 2, X_OK: 1, O_RDONLY: 0, O_WRONLY: 1, O_RDWR: 2, O_CREAT: 64, O_EXCL: 128, O_TRUNC: 512, O_APPEND: 1024, COPYFILE_EXCL: 1 }

const fs = {
  appendFileSync: (value, data, options) => writeFileSync(value, data, { ...(typeof options === "object" && options !== null ? options : {}), flag: "a" }),
  chmodSync: (value, mode) => host("fs_chmod", { path: pathOf(value), mode }),
  linkSync: (existing, value) => host("fs_link", { existing: pathOf(existing), path: pathOf(value) }),
  truncateSync: (value, length = 0) => host("fs_truncate", { path: pathOf(value), length }),
  accessSync: (value) => {
    if (!existsSync(value)) throw coded('ENOENT', 'ENOENT: no such file or directory, access ' + pathOf(value))
  },
  closeSync,
  constants: fsConstants,
  copyFileSync: (from, to) => host('fs_copy', { from: pathOf(from), to: pathOf(to), recursive: false }),
  createReadStream: fail('fs.createReadStream'),
  existsSync,
  lstatSync: (value, options) => statOf(value, false, options),
  mkdirSync: (value, options) => host('fs_mkdir', { path: pathOf(value), recursive: options?.recursive === true }),
  mkdtempSync: (prefix) => host('fs_mkdtemp', { prefix }).path,
  openSync,
  readFileSync,
  readSync,
  readdirSync: (value, options) => {
    const entries = host('fs_readdir', { path: pathOf(value) }).entries
    return options?.withFileTypes ? entries.map(direntFrom) : entries.map((entry) => entry.name)
  },
  readlinkSync: (value) => host('fs_readlink', { path: pathOf(value) }).path,
  realpathSync: (value) => host('fs_realpath', { path: pathOf(value) }).path,
  renameSync: (from, to) => host('fs_rename', { from: pathOf(from), to: pathOf(to) }),
  rmSync: (value, options) => host('fs_remove', { path: pathOf(value), recursive: options?.recursive === true, force: options?.force === true }),
  statSync: (value, options) => statOf(value, true, options),
  symlinkSync: (target, value) => host('fs_symlink', { target: pathOf(target), path: pathOf(value) }),
  unlinkSync: (value) => host('fs_remove', { path: pathOf(value), recursive: false, force: false }),
  unwatchFile: fail('fs.unwatchFile'),
  watch: (path) => {
    const id = host('watch_start', { path: String(path) }).id
    return {
      next: (timeout = 1000) => host('watch_poll', { id, timeout }).events,
      close: () => host('watch_close', { id }),
    }
  },
  watchFile: fail('fs.watchFile'),
  writeFileSync,
  writeSync,
}

const asAsync = (operation) => (...args) => new Promise((resolve) => resolve(operation(...args)))

const openHandle = (value, flags) => {
  const fd = openSync(value, flags)
  return {
    fd,
    readFile: asAsync((options) => readFileSync(fd, options)),
    writeFile: asAsync((data, options) => writeFileSync(fd, data, options)),
    stat: asAsync(() => statOf(fd, true)),
    close: asAsync(() => closeSync(fd)),
  }
}

const fsPromises = {
  access: asAsync(fs.accessSync),
  appendFile: asAsync(fs.appendFileSync),
  chmod: asAsync((value, mode) => host('fs_chmod', { path: pathOf(value), mode })),
  constants: fsConstants,
  cp: asAsync((from, to, options) => host('fs_copy', { from: pathOf(from), to: pathOf(to), recursive: options?.recursive === true })),
  link: asAsync((existing, value) => host('fs_link', { existing: pathOf(existing), path: pathOf(value) })),
  lstat: asAsync(fs.lstatSync),
  mkdir: asAsync(fs.mkdirSync),
  mkdtemp: asAsync(fs.mkdtempSync),
  open: asAsync(openHandle),
  opendir: fail('fs/promises.opendir'),
  readFile: asAsync(readFileSync),
  readdir: asAsync(fs.readdirSync),
  realpath: asAsync(fs.realpathSync),
  rename: asAsync(fs.renameSync),
  rm: asAsync(fs.rmSync),
  stat: asAsync(fs.statSync),
  truncate: asAsync((value, length = 0) => host('fs_truncate', { path: pathOf(value), length })),
  unlink: asAsync(fs.unlinkSync),
  writeFile: asAsync(writeFileSync),
}

const cryptoBytes = (size) => decodeBase64(host('random_bytes', { n: size }).base64)

const randomBytes = (size, callback) => {
  const bytes = cryptoBytes(size)
  if (typeof callback === 'function') {
    Promise.resolve().then(() => callback(null, bytes))
    return undefined
  }
  return bytes
}

const randomUUID = () => {
  const bytes = cryptoBytes(16)
  bytes[6] = (bytes[6] & 0x0f) | 0x40
  bytes[8] = (bytes[8] & 0x3f) | 0x80
  const hex = encodeHex(bytes)
  return hex.slice(0, 8) + '-' + hex.slice(8, 12) + '-' + hex.slice(12, 16) + '-' + hex.slice(16, 20) + '-' + hex.slice(20)
}

const createHash = (algorithm) => {
  const chunks = []
  const hash = {
    update(data, encoding) {
      chunks.push(toBytes(data, encoding))
      return hash
    },
    digest(encoding) {
      const reply = host('hash_digest', { algorithm, base64: encodeBase64(concatBytes(chunks)) })
      return fromBytes(decodeHex(reply.hex), encoding)
    },
  }
  return hash
}

const crypto = { createHash, randomBytes, randomUUID }

const stream = { PassThrough: fail('stream.PassThrough'), Readable: fail('stream.Readable'), Writable: fail('stream.Writable'), pipeline: fail('stream.pipeline') }

const Buffer = fail('buffer.Buffer')
Buffer.from = fail('buffer.Buffer.from')
Buffer.alloc = fail('buffer.Buffer.alloc')
Buffer.byteLength = fail('buffer.Buffer.byteLength')
Buffer.isBuffer = () => false

const buffer = { Buffer, constants: { MAX_LENGTH: 4294967296, MAX_STRING_LENGTH: 536870888 } }

class TextDecoder {
  constructor(encoding = 'utf-8') {
    this.encoding = encoding
  }
  decode(input) {
    return input === undefined ? '' : decodeUtf8(toBytes(input))
  }
}

const inspect = (value) => {
  if (typeof value === 'string') return "'" + value + "'"
  try {
    return JSON.stringify(value) ?? String(value)
  } catch {
    return String(value)
  }
}

const isDeepStrictEqual = (left, right) => {
  if (Object.is(left, right)) return true
  if (typeof left !== 'object' || typeof right !== 'object' || left === null || right === null) return false
  if (Object.getPrototypeOf(left) !== Object.getPrototypeOf(right)) return false
  const leftKeys = Object.keys(left)
  const rightKeys = Object.keys(right)
  if (leftKeys.length !== rightKeys.length) return false
  return leftKeys.every((key) => Object.prototype.hasOwnProperty.call(right, key) && isDeepStrictEqual(left[key], right[key]))
}

const parseEnv = (content) => {
  const out = {}
  for (const line of String(content).split('\n')) {
    const trimmed = line.trim()
    const index = trimmed.indexOf('=')
    if (trimmed === '' || trimmed.startsWith('#') || index === -1) continue
    out[trimmed.slice(0, index).trim()] = trimmed.slice(index + 1).trim().replace(/^(['"])(.*)\1$/, '$2')
  }
  return out
}

const promisify = (operation) => (...args) => new Promise((resolve, reject) => {
  operation(...args, (error, value) => (error ? reject(error) : resolve(value)))
})

const util = { TextDecoder, inspect, isDeepStrictEqual, parseArgs: fail('util.parseArgs'), parseEnv, promisify }

const utilTypes = { isPromise: (value) => value instanceof Promise }

const moduleApi = { createRequire: fail('module.createRequire'), stripTypeScriptTypes: fail('module.stripTypeScriptTypes') }

const runCommand = (file, argv, options) => {
  const reply = host('run_command', {
    file: String(file),
    args: argv.map(String),
    cwd: options.cwd ?? null,
    env: options.env ?? null,
    input_base64: options.input === undefined ? null : encodeBase64(toBytes(options.input)),
    timeout_ms: options.timeout ?? null,
  })
  return {
    status: reply.status,
    signal: reply.signal ?? null,
    stdout: decodeBase64(reply.stdout_base64),
    stderr: decodeBase64(reply.stderr_base64),
  }
}

const normalizeExecArgs = (args, options) => (Array.isArray(args) ? { argv: args, options: options ?? {} } : { argv: [], options: args ?? {} })

const commandFailure = (file, argv, result, options) => {
  const error = coded('ERR_CHILD_PROCESS_FAILED', 'Command failed: ' + [file, ...argv].join(' '))
  error.status = result.status
  error.signal = result.signal
  error.stdout = fromBytes(result.stdout, encodingOf(options))
  error.stderr = fromBytes(result.stderr, encodingOf(options))
  return error
}

const execFileSync = (file, args, options) => {
  const { argv, options: resolved } = normalizeExecArgs(args, options)
  const result = runCommand(file, argv, resolved)
  if (result.status !== 0) throw commandFailure(file, argv, result, resolved)
  return fromBytes(result.stdout, encodingOf(resolved))
}

const spawnSync = (file, args, options) => {
  const { argv, options: resolved } = normalizeExecArgs(args, options)
  const result = runCommand(file, argv, resolved)
  const stdout = fromBytes(result.stdout, encodingOf(resolved))
  const stderr = fromBytes(result.stderr, encodingOf(resolved))
  return { pid: 0, output: [null, stdout, stderr], stdout, stderr, status: result.status, signal: result.signal, error: undefined }
}

const execFile = (file, ...rest) => {
  const callback = typeof rest[rest.length - 1] === 'function' ? rest.pop() : undefined
  const { argv, options } = normalizeExecArgs(rest[0], rest[1])
  let failure = null
  let stdout
  let stderr
  try {
    const result = runCommand(file, argv, options)
    stdout = fromBytes(result.stdout, encodingOf(options))
    stderr = fromBytes(result.stderr, encodingOf(options))
    if (result.status !== 0) failure = commandFailure(file, argv, result, options)
  } catch (error) {
    failure = error
  }
  if (typeof callback === 'function') Promise.resolve().then(() => callback(failure, stdout, stderr))
  return undefined
}

const spawnStreams = (file, args = [], options = {}) => {
  const request = { file, args: args.map(String) }
  if (options.cwd !== undefined) request.cwd = String(options.cwd)
  if (options.env !== undefined) request.env_json = JSON.stringify(Object.fromEntries(Object.entries(options.env).map(([key, value]) => [key, String(value)])))
  const pid = host('proc_spawn', request).id
  const pump = (stream) => ({ read: async () => {
    const reply = host('proc_read', { id: pid, stream })
    return reply.eof ? null : fromBytes(decodeBase64(reply.body), 'utf8')
  } })
  return {
    pid,
    stdin: {
      write: async (data) => host('proc_write', { id: pid, body: encodeBase64(toBytes(data, 'utf8')) }),
      end: async () => host('proc_close_stdin', { id: pid }),
    },
    stdout: pump('stdout'),
    stderr: pump('stderr'),
    wait: async () => host('proc_wait', { id: pid }).code,
    kill: () => host('proc_kill', { id: pid }),
  }
}
const childProcess = { execFile, execFileSync, spawn: spawnStreams, spawnSync }

const os = {
  availableParallelism: () => processInfo().parallelism,
  constants: { signals: {}, errno: {} },
  homedir: () => processInfo().homedir,
  networkInterfaces: fail('os.networkInterfaces'),
  platform: () => processInfo().platform,
  release: () => processInfo().release,
  tmpdir: () => processInfo().tmpdir,
}

const workerThreads = { MessageChannel: fail('worker_threads.MessageChannel'), Worker: fail('worker_threads.Worker'), parentPort: null, workerData: null }

const asyncHooks = { AsyncLocalStorage: fail('async_hooks.AsyncLocalStorage') }

const vm = { Script: fail('vm.Script'), createContext: fail('vm.createContext'), runInContext: fail('vm.runInContext') }

const http = { createServer: fail('http.createServer'), validateHeaderValue: fail('http.validateHeaderValue') }

const https = { createServer: fail('https.createServer'), get: fail('https.get'), request: fail('https.request') }

const zlib = {
  brotliCompress: fail('zlib.brotliCompress'),
  constants: {},
  createZstdDecompress: fail('zlib.createZstdDecompress'),
  gzip: fail('zlib.gzip'),
  zstdCompress: fail('zlib.zstdCompress'),
  zstdDecompress: fail('zlib.zstdDecompress'),
  zstdDecompressSync: fail('zlib.zstdDecompressSync'),
}

const inspector = { Session: fail('inspector.Session') }

class StringDecoder {
  constructor(encoding = 'utf8') {
    this.encoding = encoding
    this.pending = new Uint8Array(0)
  }
  write(chunk) {
    const bytes = concatBytes([this.pending, toBytes(chunk)])
    if (this.encoding !== 'utf8' && this.encoding !== 'utf-8') return fromBytes(bytes, this.encoding)
    const tail = incompleteTail(bytes)
    this.pending = bytes.slice(bytes.length - tail)
    return decodeUtf8(bytes.subarray(0, bytes.length - tail))
  }
  end(chunk) {
    const text = chunk === undefined ? '' : this.write(chunk)
    const rest = this.pending
    this.pending = new Uint8Array(0)
    return text + decodeUtf8(rest)
  }
}

const incompleteTail = (bytes) => {
  for (let back = 1; back <= Math.min(3, bytes.length); back += 1) {
    const byte = bytes[bytes.length - back]
    if ((byte & 0xc0) === 0x80) continue
    const needed = byte >= 0xf0 ? 4 : byte >= 0xe0 ? 3 : byte >= 0xc0 ? 2 : 1
    return needed > back ? back : 0
  }
  return 0
}

const stringDecoder = { StringDecoder }

const perfHooks = { performance: fail('perf_hooks.performance') }

const timersPromises = {
  scheduler: {
    wait: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
    yield: () => new Promise((resolve) => setTimeout(resolve, 0)),
  },
  setTimeout: (ms, value) => new Promise((resolve) => setTimeout(() => resolve(value), ms)),
}

const net = {
  isIP: (text) => {
    if (/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.test(text)) return 4
    if (text.includes(':') && /^[0-9a-fA-F:.]+$/.test(text)) return 6
    return 0
  },
}

const dnsPromises = {
  lookup: async (hostname) => {
    const reply = host('dns_lookup', { url: 'https://' + String(hostname) + '/' })
    return { address: reply.address, family: reply.family }
  },
  resolve: fail('dns.resolve'),
}

const processObject = {
  get env() { return processInfo().env },
  get argv() { return processInfo().argv },
  get pid() { return processInfo().pid },
  get platform() { return processInfo().platform },
  get version() { return processInfo().version },
  exitCode: undefined,
  cwd: () => processInfo().cwd,
  exit: fail('process.exit'),
  nextTick: (callback, ...args) => {
    Promise.resolve().then(() => callback(...args))
  },
  stdout: { write: (text) => {
    globalThis.console.log(String(text).replace(/\n$/, ''))
    return true
  } },
  stderr: { write: (text) => {
    globalThis.console.error(String(text).replace(/\n$/, ''))
    return true
  } },
}

const fetch = async (input, init = {}) => {
  const target = typeof input === 'string' ? input : String(input.url)
  const method = init.method === undefined ? 'GET' : String(init.method).toUpperCase()
  const body = init.body === undefined || init.body === null ? undefined : encodeBase64(toBytes(init.body, 'utf8'))
  const reply = host('net_fetch', { url: target, method, body, loopback: init.allowLoopback === true })
  const text = fromBytes(decodeBase64(reply.body), 'utf8')
  return { ok: reply.status >= 200 && reply.status < 300, status: reply.status, url: reply.url, text: async () => text, json: async () => JSON.parse(text) }
}
globalThis.fetch = fetch

export const fxRuntime = {
  fetch,
  fs,
  fsPromises,
  path,
  crypto,
  stream,
  buffer,
  url,
  util,
  utilTypes,
  module: moduleApi,
  childProcess,
  os,
  workerThreads,
  asyncHooks,
  vm,
  http,
  https,
  zlib,
  inspector,
  stringDecoder,
  perfHooks,
  timersPromises,
  net,
  dnsPromises,
  process: processObject,
}
