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

class FxEmitter {
  constructor() { this.listeners = new Map() }
  on(event, listener) {
    const list = this.listeners.get(event) ?? []
    list.push(listener)
    this.listeners.set(event, list)
    return this
  }
  once(event, listener) {
    const wrapper = (...args) => {
      this.off(event, wrapper)
      listener(...args)
    }
    return this.on(event, wrapper)
  }
  off(event, listener) {
    this.listeners.set(event, (this.listeners.get(event) ?? []).filter((item) => item !== listener))
    return this
  }
  emit(event, ...args) {
    for (const listener of [...(this.listeners.get(event) ?? [])]) listener(...args)
    return (this.listeners.get(event) ?? []).length > 0
  }
}

class Readable extends FxEmitter {
  constructor(options = {}) {
    super()
    this.buffered = []
    this.ended = false
    this.readableEnded = false
    this.flowing = false
    this.encoding = options.encoding ?? null
    this.objectMode = options.objectMode ?? false
  }
  push(chunk) {
    if (chunk === null) this.ended = true
    else this.buffered.push(chunk)
    this.flow()
    return chunk !== null
  }
  flow() {
    if (!this.flowing) return
    while (this.buffered.length > 0) this.emit('data', this.buffered.shift())
    if (this.ended && !this.readableEnded) {
      this.readableEnded = true
      this.emit('end')
    }
  }
  on(event, listener) {
    super.on(event, listener)
    if (event === 'data') {
      this.flowing = true
      this.flow()
    }
    return this
  }
  resume() {
    this.flowing = true
    this.flow()
    return this
  }
  read() {
    return this.buffered.length > 0 ? this.buffered.shift() : null
  }
  setEncoding(encoding) {
    this.encoding = encoding
    return this
  }
  pipe(destination) {
    this.on('data', (chunk) => destination.write(chunk))
    this.on('end', () => destination.end())
    return destination
  }
  static from(iterable) {
    const readable = new Readable({ objectMode: true })
    const pump = async () => {
      for await (const chunk of iterable) readable.push(chunk)
      readable.push(null)
    }
    pump()
    return readable
  }
}

class Writable extends FxEmitter {
  constructor(options = {}) {
    super()
    this.writeImpl = options.write ?? null
    this.chunks = []
    this.finished = false
  }
  write(chunk, encoding, callback) {
    const done = typeof encoding === 'function' ? encoding : callback
    if (this.writeImpl !== null) this.writeImpl(chunk, typeof encoding === 'string' ? encoding : 'buffer', done ?? (() => {}))
    else this.chunks.push(chunk)
    return true
  }
  end(chunk) {
    if (chunk !== undefined && chunk !== null) this.write(chunk)
    if (!this.finished) {
      this.finished = true
      this.emit('finish')
      this.emit('close')
    }
    return this
  }
}

class PassThrough extends Readable {
  write(chunk) {
    this.push(chunk)
    return true
  }
  end(chunk) {
    if (chunk !== undefined && chunk !== null) this.push(chunk)
    this.push(null)
    this.emit('finish')
    return this
  }
}

const pipeline = (...streams) => {
  const callback = typeof streams[streams.length - 1] === 'function' ? streams.pop() : () => {}
  for (let index = 0; index < streams.length - 1; index += 1) streams[index].pipe(streams[index + 1])
  const last = streams[streams.length - 1]
  let finished = false
  const finish = (error) => {
    if (finished) return
    finished = true
    callback(error)
  }
  last.on('finish', () => finish())
  last.on('error', (error) => finish(error))
  return last
}

const stream = { PassThrough, Readable, Writable, Transform: PassThrough, pipeline }

class FxBuffer extends Uint8Array {
  toString(encoding, start = 0, end = this.length) {
    return fromBytes(this.subarray(start, end), encoding ?? 'utf8')
  }
}

const wrapBytes = (bytes) => new FxBuffer(bytes.buffer, bytes.byteOffset, bytes.byteLength)

const Buffer = FxBuffer
Buffer.from = (value, encoding) => {
  if (typeof value === 'string') return wrapBytes(toBytes(value, encoding))
  if (value instanceof ArrayBuffer || ArrayBuffer.isView(value)) return wrapBytes(new Uint8Array(value))
  if (Array.isArray(value)) return wrapBytes(Uint8Array.from(value))
  throw new TypeError('Buffer.from received an unsupported value')
}
Buffer.alloc = (size, fill = 0) => {
  const bytes = new Uint8Array(size)
  if (fill !== 0) bytes.fill(typeof fill === 'string' ? toBytes(fill, 'utf8')[0] : fill)
  return wrapBytes(bytes)
}
Buffer.byteLength = (value, encoding) => (typeof value === 'string' ? toBytes(value, encoding).length : value.byteLength)
Buffer.isBuffer = (value) => value instanceof FxBuffer
Buffer.concat = (list) => wrapBytes(concatBytes(list))

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

class AsyncLocalStorage {
  constructor() { this.store = undefined }
  getStore() { return this.store }
  run(store, callback, ...args) {
    const previous = this.store
    this.store = store
    try { return callback(...args) } finally { this.store = previous }
  }
  exit(callback, ...args) {
    const previous = this.store
    this.store = undefined
    try { return callback(...args) } finally { this.store = previous }
  }
  enterWith(store) { this.store = store }
}

const asyncHooks = { AsyncLocalStorage }

const vm = { Script: fail('vm.Script'), createContext: fail('vm.createContext'), runInContext: fail('vm.runInContext') }

const validateHeaderValue = (name, value) => {
  if (value === undefined) throw new TypeError('Invalid value "undefined" for header "' + String(name) + '"')
  if (/[\r\n\0]/.test(String(value))) throw new TypeError('Invalid character in header content ["' + String(name) + '"]')
}

const http = { createServer: fail('http.createServer'), validateHeaderValue }

const https = { createServer: fail('https.createServer'), get: fail('https.get'), request: fail('https.request') }

const CRC_TABLE = (() => {
  const table = new Uint32Array(256)
  for (let index = 0; index < 256; index += 1) {
    let value = index
    for (let bit = 0; bit < 8; bit += 1) value = value & 1 ? 0xedb88320 ^ (value >>> 1) : value >>> 1
    table[index] = value >>> 0
  }
  return table
})()

const crc32 = (bytes) => {
  let crc = 0xffffffff
  for (const byte of bytes) crc = CRC_TABLE[(crc ^ byte) & 0xff] ^ (crc >>> 8)
  return (crc ^ 0xffffffff) >>> 0
}

const adler32 = (bytes) => {
  let a = 1
  let b = 0
  for (const byte of bytes) {
    a = (a + byte) % 65521
    b = (b + a) % 65521
  }
  return ((b << 16) | a) >>> 0
}

const storedDeflate = (bytes) => {
  const parts = []
  let offset = 0
  do {
    const size = Math.min(65535, bytes.length - offset)
    const final = offset + size >= bytes.length ? 1 : 0
    parts.push(new Uint8Array([final, size & 0xff, size >>> 8, (~size) & 0xff, ((~size) >>> 8) & 0xff]))
    parts.push(bytes.subarray(offset, offset + size))
    offset += size
  } while (offset < bytes.length)
  return concatBytes(parts)
}

const u32le = (value) => new Uint8Array([value & 0xff, (value >>> 8) & 0xff, (value >>> 16) & 0xff, (value >>> 24) & 0xff])
const u32be = (value) => new Uint8Array([(value >>> 24) & 0xff, (value >>> 16) & 0xff, (value >>> 8) & 0xff, value & 0xff])

const LENGTH_BASE = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
const LENGTH_EXTRA = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
const DIST_BASE = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
const DIST_EXTRA = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
const CODE_ORDER = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

const buildHuffman = (lengths) => {
  const count = new Uint16Array(16)
  for (const length of lengths) count[length] += 1
  const offsets = new Uint16Array(16)
  for (let length = 1; length < 15; length += 1) offsets[length + 1] = offsets[length] + count[length]
  const symbol = new Uint16Array(lengths.length)
  for (let index = 0; index < lengths.length; index += 1) {
    if (lengths[index] !== 0) symbol[offsets[lengths[index]]++] = index
  }
  return { count, symbol }
}

const inflateBits = (input) => {
  let pos = 0
  let buffer = 0
  let count = 0
  const bits = (need) => {
    while (count < need) {
      if (pos >= input.length) throw new Error('zlib: unexpected end of input')
      buffer |= input[pos] << count
      pos += 1
      count += 8
    }
    const value = buffer & ((1 << need) - 1)
    buffer >>>= need
    count -= need
    return value
  }
  const decode = (huffman) => {
    let code = 0
    let first = 0
    let index = 0
    for (let length = 1; length <= 15; length += 1) {
      code |= bits(1)
      const number = huffman.count[length]
      if (code - number < first) return huffman.symbol[index + (code - first)]
      index += number
      first += number
      first <<= 1
      code <<= 1
    }
    throw new Error('zlib: invalid Huffman code')
  }
  const align = () => {
    buffer = 0
    count = 0
  }
  const consumed = () => pos - Math.floor(count / 8)
  return { bits, decode, align, consumed }
}

const inflateRaw = (input) => {
  const reader = inflateBits(input)
  const out = []
  let final = 0
  while (!final) {
    final = reader.bits(1)
    const type = reader.bits(2)
    if (type === 0) {
      reader.align()
      const length = input[reader.consumed()] | (input[reader.consumed() + 1] << 8)
      const start = reader.consumed() + 4
      for (let index = 0; index < length; index += 1) out.push(input[start + index])
      reader.bits(0)
      for (let index = 0; index < length + 4; index += 1) reader.bits(8)
      continue
    }
    let literals
    let distances
    if (type === 1) {
      const lengths = new Uint8Array(288)
      lengths.fill(8, 0, 144)
      lengths.fill(9, 144, 256)
      lengths.fill(7, 256, 280)
      lengths.fill(8, 280, 288)
      literals = buildHuffman(lengths)
      distances = buildHuffman(new Uint8Array(30).fill(5))
    } else if (type === 2) {
      const nlen = reader.bits(5) + 257
      const ndist = reader.bits(5) + 1
      const ncode = reader.bits(4) + 4
      const codeLengths = new Uint8Array(19)
      for (let index = 0; index < ncode; index += 1) codeLengths[CODE_ORDER[index]] = reader.bits(3)
      const lengthCode = buildHuffman(codeLengths)
      const lengths = []
      while (lengths.length < nlen + ndist) {
        const symbol = reader.decode(lengthCode)
        if (symbol < 16) lengths.push(symbol)
        else if (symbol === 16) {
          const previous = lengths[lengths.length - 1]
          for (let repeat = 3 + reader.bits(2); repeat > 0; repeat -= 1) lengths.push(previous)
        } else if (symbol === 17) {
          for (let repeat = 3 + reader.bits(3); repeat > 0; repeat -= 1) lengths.push(0)
        } else {
          for (let repeat = 11 + reader.bits(7); repeat > 0; repeat -= 1) lengths.push(0)
        }
      }
      literals = buildHuffman(lengths.slice(0, nlen))
      distances = buildHuffman(lengths.slice(nlen, nlen + ndist))
    } else throw new Error('zlib: invalid block type')
    for (;;) {
      const symbol = reader.decode(literals)
      if (symbol < 256) out.push(symbol)
      else if (symbol === 256) break
      else {
        const lengthIndex = symbol - 257
        const length = LENGTH_BASE[lengthIndex] + reader.bits(LENGTH_EXTRA[lengthIndex])
        const distanceIndex = reader.decode(distances)
        const distance = DIST_BASE[distanceIndex] + reader.bits(DIST_EXTRA[distanceIndex])
        for (let index = 0; index < length; index += 1) out.push(out[out.length - distance])
      }
    }
  }
  return { data: Uint8Array.from(out), consumed: reader.consumed() }
}

const gzipBytes = (bytes) => concatBytes([
  new Uint8Array([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3]),
  storedDeflate(bytes),
  u32le(crc32(bytes)),
  u32le(bytes.length >>> 0),
])

const gunzipBytes = (input) => {
  if (input[0] !== 0x1f || input[1] !== 0x8b) throw new Error('zlib: not a gzip stream')
  const flags = input[3]
  let pos = 10
  if (flags & 4) pos += 2 + (input[pos] | (input[pos + 1] << 8))
  if (flags & 8) while (input[pos++] !== 0);
  if (flags & 16) while (input[pos++] !== 0);
  if (flags & 2) pos += 2
  const result = inflateRaw(input.subarray(pos))
  const trailer = pos + result.consumed
  const expected = (input[trailer] | (input[trailer + 1] << 8) | (input[trailer + 2] << 16) | (input[trailer + 3] << 24)) >>> 0
  if (expected !== crc32(result.data)) throw new Error('zlib: gzip CRC mismatch')
  return result.data
}

const deflateBytes = (bytes) => concatBytes([new Uint8Array([0x78, 0x01]), storedDeflate(bytes), u32be(adler32(bytes))])

const inflateBytes = (input) => {
  if ((input[0] & 0x0f) !== 8 || ((input[0] << 8) | input[1]) % 31 !== 0) throw new Error('zlib: invalid zlib header')
  const result = inflateRaw(input.subarray(2))
  const trailer = 2 + result.consumed
  const expected = ((input[trailer] << 24) | (input[trailer + 1] << 16) | (input[trailer + 2] << 8) | input[trailer + 3]) >>> 0
  if (expected !== adler32(result.data)) throw new Error('zlib: Adler-32 mismatch')
  return result.data
}

const asInput = (data) => (typeof data === 'string' ? encodeUtf8(data) : toBytes(data, undefined))

const zlib = {
  gzipSync: (data) => wrapBytes(gzipBytes(asInput(data))),
  gunzipSync: (data) => wrapBytes(gunzipBytes(asInput(data))),
  deflateSync: (data) => wrapBytes(deflateBytes(asInput(data))),
  inflateSync: (data) => wrapBytes(inflateBytes(asInput(data))),
  gzip: (data, callback) => { queueMicrotask(() => callback(null, wrapBytes(gzipBytes(asInput(data))))) },
  gunzip: (data, callback) => { queueMicrotask(() => callback(null, wrapBytes(gunzipBytes(asInput(data))))) },
  deflate: (data, callback) => { queueMicrotask(() => callback(null, wrapBytes(deflateBytes(asInput(data))))) },
  inflate: (data, callback) => { queueMicrotask(() => callback(null, wrapBytes(inflateBytes(asInput(data))))) },
  brotliCompress: fail('zlib.brotliCompress'),
  constants: {},
  createZstdDecompress: fail('zlib.createZstdDecompress'),
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

const performanceClock = { now: () => Date.now() }
const perfHooks = { performance: globalThis.performance ?? performanceClock }

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

const serveModule = {
  serve: (options = {}) => {
    const bind = options.host ?? '127.0.0.1'
    const reply = host('serve_listen', { url: 'http://' + bind + '/', loopback: true, host: bind, port: options.port ?? 0 })
    const id = reply.id
    return {
      port: reply.port,
      accept: () => {
        const request = host('serve_accept', { id })
        return {
          method: request.method,
          path: request.path,
          upgrade: request.upgrade,
          body: request.body,
          respond: (status, body = '') => host('serve_respond', { conn: request.conn, status, body: String(body) }),
          websocket: {
            send: (text) => host('ws_send', { conn: request.conn, body: String(text) }),
            recv: () => host('ws_recv', { conn: request.conn }).body,
            recvFrame: () => host('ws_recv', { conn: request.conn }),
          },
        }
      },
    }
  },
}

const ptyModule = {
  spawn: (file, args = []) => {
    const id = host('pty_spawn', { file, args: args.map(String) }).id
    return {
      write: (text) => host('pty_write', { id, body: encodeBase64(toBytes(String(text), 'utf8')) }),
      read: () => {
        const reply = host('pty_read', { id })
        return reply.eof ? null : fromBytes(decodeBase64(reply.body), 'utf8')
      },
      wait: () => host('pty_wait', { id }).code,
    }
  },
}

const sqliteModule = {
  open: (path) => {
    const id = host('sqlite_open', { path: String(path) }).id
    return {
      exec: (sql) => host('sqlite_exec', { id, sql: String(sql) }),
      all: (sql) => host('sqlite_all', { id, sql: String(sql) }).rows,
      close: () => host('sqlite_close', { id }),
    }
  },
}

const fetchModule = { fetch }

const agentModule = { core: { name: 'fx', interface: 1 } }

const loaderState = { lastGood: new Map(), hot: new Map(), rev: new Map(), reloads: 0, history: new Map() }

const hashText = (text) => {
  let hash = 5381
  for (let index = 0; index < text.length; index += 1) hash = ((hash * 33) ^ text.charCodeAt(index)) >>> 0
  return hash.toString(16)
}

const normalizePath = (path) => {
  const parts = []
  for (const segment of path.split('/')) {
    if (segment === '' || segment === '.') continue
    if (segment === '..') parts.pop()
    else parts.push(segment)
  }
  return '/' + parts.join('/')
}

const readText = (path) => fromBytes(decodeBase64(host('fs_read', { path }).base64), 'utf8')

const relativeImport = /from\s+(['"])(\.\.?\/[^'"]+)\1/g

const depsOf = (target, text) => {
  const dir = target.slice(0, target.lastIndexOf('/'))
  const found = []
  const scan = new RegExp(relativeImport.source, 'g')
  let match
  while ((match = scan.exec(text)) !== null) found.push(normalizePath(dir + '/' + match[2]))
  return found
}

const linkDeps = (target, text) => {
  const dir = target.slice(0, target.lastIndexOf('/'))
  return text.replace(new RegExp(relativeImport.source, 'g'), (match, quote, spec) => {
    const revision = loaderState.rev.get(normalizePath(dir + '/' + spec))
    return revision === undefined ? match : 'from ' + quote + revision + quote
  })
}

const hotEntry = (target) => {
  let entry = loaderState.hot.get(target)
  if (entry === undefined) {
    entry = { data: {}, disposers: [], acceptors: [] }
    loaderState.hot.set(target, entry)
  }
  return entry
}

const hotFor = (target) => {
  const entry = hotEntry(target)
  return {
    data: entry.data,
    accept: (deps, callback) => { entry.acceptors.push(typeof deps === 'function' ? deps : callback) },
    dispose: (callback) => { entry.disposers.push(callback) },
    invalidate: () => {},
    decline: () => {},
  }
}

const reloadModule = async (path) => {
  const target = String(path)
  const text = readText(target)
  const entry = hotEntry(target)
  for (const callback of entry.disposers) callback(entry.data)
  entry.disposers = []
  const linked = linkDeps(target, text).split('import.meta.hot').join('__fxHot')
  const rewritten = "import { hotFor as __fxHotFor } from 'fx:host/loader'\nconst __fxHot = __fxHotFor(" + JSON.stringify(target) + ')\n' + linked
  const revision = target.slice(0, target.lastIndexOf('/')) + '/.fx-rev-' + hashText(rewritten) + '.mjs'
  host('fs_write', { path: revision, base64: encodeBase64(toBytes(rewritten, 'utf8')), append: false })
  try {
    const mod = await import(revision)
    loaderState.lastGood.set(target, mod)
    loaderState.rev.set(target, revision)
    loaderState.reloads += 1
    const past = loaderState.history.get(target) ?? []
    past.push(revision)
    loaderState.history.set(target, past)
    for (const callback of entry.acceptors) callback(mod)
    return mod
  } catch (error) {
    if (loaderState.lastGood.has(target)) return loaderState.lastGood.get(target)
    throw error
  }
}

const watchState = { ids: new Map(), dirty: new Set(), files: new Set(), order: [], entry: null }

const watchGraph = async (entry) => {
  const target = String(entry)
  const order = []
  const seen = new Set()
  const visit = (file) => {
    if (seen.has(file)) return
    seen.add(file)
    for (const dep of depsOf(file, readText(file))) visit(dep)
    order.push(file)
  }
  visit(target)
  for (const file of order) await reloadModule(file)
  for (const dir of new Set(order.map((file) => file.slice(0, file.lastIndexOf('/'))))) {
    watchState.ids.set(host('watch_start', { path: dir }).id, dir)
  }
  watchState.files = new Set(order)
  watchState.order = order
  watchState.entry = target
  return loaderState.lastGood.get(target)
}

const pollGraph = () => {
  for (const [id, dir] of watchState.ids) {
    for (const event of host('watch_poll', { id, timeout: 0 }).events) {
      const file = dir + '/' + event.name
      if (watchState.files.has(file)) watchState.dirty.add(file)
    }
  }
}

const currentModule = async (entry) => {
  pollGraph()
  if (watchState.dirty.size > 0) {
    watchState.dirty = new Set()
    for (const file of watchState.order) await reloadModule(file)
  }
  return loaderState.lastGood.get(String(entry))
}

const rollbackModule = async (path) => {
  const target = String(path)
  const past = loaderState.history.get(target) ?? []
  if (past.length < 2) throw new Error('nothing to roll back to for ' + target)
  past.pop()
  const previous = past[past.length - 1]
  const mod = await import(previous)
  loaderState.lastGood.set(target, mod)
  loaderState.rev.set(target, previous)
  return { revision: previous, module: mod }
}

const loaderModule = { reload: reloadModule, hotFor, watchGraph, current: currentModule, reloadCount: () => loaderState.reloads, rollback: rollbackModule }

const wsModule = {
  connect: (hostname, port, path = '/') => {
    const id = host('ws_connect', { url: 'http://' + String(hostname) + ':' + String(port) + String(path), loopback: true, path: String(path) }).conn
    return {
      send: (text) => host('ws_send', { conn: id, body: String(text) }),
      recv: () => host('ws_recv', { conn: id }).body,
      close: () => host('ws_close', { conn: id }),
    }
  },
}

export const fxRuntime = {
  serveModule,
  ptyModule,
  sqliteModule,
  fetchModule,
  agentModule,
  wsModule,
  loaderModule,
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
