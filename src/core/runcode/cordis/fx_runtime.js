const ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

const coded = (code, message) => {
  const error = new Error(message)
  error.code = code
  return error
}

const fail = (name) => function unsupportedFunction() {
  throw coded('ERR_FX_UNSUPPORTED', name + ' is not available in fx: the embedded runtime does not provide it')
}

const hostErrnoCodes = { FileNotFound: 'ENOENT', NotDir: 'ENOTDIR', AccessDenied: 'EACCES', PermissionDenied: 'EACCES', IsDir: 'EISDIR', PathAlreadyExists: 'EEXIST' }

const fsErrnoText = { ENOENT: 'no such file or directory', EEXIST: 'file already exists', ENOTDIR: 'not a directory', EISDIR: 'illegal operation on a directory', EACCES: 'permission denied' }
const fsVerbSyscalls = { fs_read: 'open', fs_stat: 'stat', fs_readdir: 'scandir', fs_mkdir: 'mkdir' }
const hostFailure = (name, args, reply) => {
  const code = reply.code ?? hostErrnoCodes[reply.error] ?? 'EFXHOST'
  const syscall = fsVerbSyscalls[name]
  if (fsErrnoText[code] === undefined || syscall === undefined || args?.path === undefined) return coded(code, reply.error ?? name + ' failed')
  const error = coded(code, code + ': ' + fsErrnoText[code] + ', ' + syscall + " '" + args.path + "'")
  error.syscall = syscall
  error.path = args.path
  return error
}
const host = (name, args) => {
  const reply = globalThis.gm[name](args ?? {})
  if (reply === null || typeof reply !== 'object') throw coded('EFXHOST', 'fx host verb ' + name + ' returned no reply')
  if (reply.ok === false) throw hostFailure(name, args, reply)
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
    if (lead < 0x80) {
      out += String.fromCharCode(lead)
      i += 1
      continue
    }
    let need = 0
    let code = 0
    let min = 0
    if (lead >= 0xc2 && lead <= 0xdf) {
      need = 1
      code = lead & 0x1f
      min = 0x80
    } else if (lead >= 0xe0 && lead <= 0xef) {
      need = 2
      code = lead & 0x0f
      min = 0x800
    } else if (lead >= 0xf0 && lead <= 0xf4) {
      need = 3
      code = lead & 0x07
      min = 0x10000
    } else {
      out += '\ufffd'
      i += 1
      continue
    }
    let read = 1
    let valid = true
    for (; read <= need; read += 1) {
      const next = bytes[i + read]
      if (next === undefined || (next & 0xc0) !== 0x80) {
        valid = false
        break
      }
      code = (code << 6) | (next & 0x3f)
    }
    if (!valid) {
      out += '\ufffd'
      i += read
      continue
    }
    if (code < min || code > 0x10ffff || (code >= 0xd800 && code <= 0xdfff)) {
      out += '\ufffd'
    } else {
      out += String.fromCodePoint(code)
    }
    i += need + 1
  }
  return out
}

const decodeLatin1 = (bytes) => Array.from(bytes, (byte) => String.fromCharCode(byte)).join('')

const toBytes = (data, encoding) => {
  if (typeof data === 'string') {
    if (encoding === 'base64') return decodeBase64(data)
    if (encoding === 'base64url') return decodeBase64(data.replace(/-/g, '+').replace(/_/g, '/'))
    if (encoding === 'utf16le' || encoding === 'ucs2' || encoding === 'ucs-2' || encoding === 'utf-16le') {
      const out = new Uint8Array(data.length * 2)
      for (let index = 0; index < data.length; index += 1) {
        const unit = data.charCodeAt(index)
        out[index * 2] = unit & 0xff
        out[index * 2 + 1] = unit >> 8
      }
      return out
    }
    if (encoding === 'hex') return decodeHex(data)
    if (encoding === 'latin1' || encoding === 'binary' || encoding === 'ascii') return Uint8Array.from(data, (character) => character.charCodeAt(0) & 0xff)
    return encodeUtf8(data)
  }
  if (data instanceof ArrayBuffer) return new Uint8Array(data)
  if (ArrayBuffer.isView(data)) return new Uint8Array(data.buffer, data.byteOffset, data.byteLength)
  throw new TypeError('the data must be a string or binary data')
}

const fromBytes = (bytes, encoding) => {
  if (encoding === undefined || encoding === null || encoding === 'buffer') return bytes
  if (encoding === 'base64') return encodeBase64(bytes)
  if (encoding === 'base64url') return encodeBase64(bytes).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
  if (encoding === 'utf16le' || encoding === 'ucs2' || encoding === 'ucs-2' || encoding === 'utf-16le') {
    let text = ''
    for (let index = 0; index + 1 < bytes.length; index += 2) text += String.fromCharCode(bytes[index] | (bytes[index + 1] << 8))
    return text
  }
  if (encoding === 'hex') return encodeHex(bytes)
  if (encoding === 'ascii') return Array.from(bytes, (byte) => String.fromCharCode(byte & 0x7f)).join('')
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

const cpError = (code, message, errno, syscall) => {
  const error = nodeError(code, message)
  if (errno !== undefined) error.errno = errno
  if (syscall !== undefined) error.syscall = syscall
  return error
}
const cpInvalid = (detail, path) => cpError('ERR_FS_CP_EINVAL', 'Invalid src or dest: cp returned EINVAL (' + detail + ') ' + path, -22, 'cp')
const cpStatOrNull = (path, follow) => {
  try {
    return statOf(path, follow)
  } catch (error) {
    return null
  }
}
const cpIsSubdir = (parent, child) => {
  const parentParts = normalizePath(parent).split('/')
  const childParts = normalizePath(child).split('/')
  return parentParts.length <= childParts.length && parentParts.every((part, index) => childParts[index] === part)
}
const cpResolve = (base, target) => (target.startsWith('/') ? normalizePath(target) : normalizePath(base.slice(0, base.lastIndexOf('/')) + '/' + target))
const cpStatFor = (path, follow) => {
  try {
    return statOf(path, follow)
  } catch (error) {
    if (error.code === 'ENOENT') throw cpError('ENOENT', 'ENOENT: no such file or directory, ' + (follow ? 'stat' : 'lstat') + " '" + path + "'", -2, follow ? 'stat' : 'lstat')
    throw error
  }
}
const copyTree = (from, to, options = {}) => {
  const opts = { force: true, recursive: false, dereference: false, errorOnExist: false, ...options }
  const src = pathOf(from)
  const dest = pathOf(to)
  const follow = opts.dereference === true
  const srcStat = cpStatFor(src, follow)
  const destStat = cpStatOrNull(dest, follow)
  if (destStat !== null && destStat.ino === srcStat.ino && destStat.dev === srcStat.dev) throw cpInvalid('src and dest cannot be the same', dest)
  if (srcStat.isDirectory() && !opts.recursive) throw cpError('ERR_FS_EISDIR', 'Recursive option is required to copy a directory: ' + src, -21, 'cp')
  if (destStat !== null) {
    if (srcStat.isDirectory() && !destStat.isDirectory()) throw cpError('ERR_FS_CP_DIR_TO_NON_DIR', 'Cannot overwrite non-directory with directory: cp returned EISDIR (cannot overwrite non-directory ' + dest + ' with directory ' + src + ') ' + dest, -21, 'cp')
    if (!srcStat.isDirectory() && destStat.isDirectory()) throw cpError('ERR_FS_CP_NON_DIR_TO_DIR', 'Cannot overwrite directory with non-directory: cp returned ENOTDIR (cannot overwrite directory ' + dest + ' with non-directory ' + src + ') ' + dest, -20, 'cp')
  }
  if (srcStat.isDirectory() && cpIsSubdir(src, dest)) throw cpInvalid('cannot copy ' + src + ' to a subdirectory of self ' + dest, dest)
  if (srcStat.isSymbolicLink()) return copyLink(src, dest, destStat, opts)
  if (srcStat.isDirectory()) {
    if (destStat === null) host('fs_mkdir', { path: dest, recursive: false })
    for (const name of fs.readdirSync(src)) copyTree(src + '/' + name, dest + '/' + name, opts)
    return undefined
  }
  if (destStat !== null) {
    if (!opts.force) {
      if (opts.errorOnExist) throw cpError('ERR_FS_CP_EEXIST', 'Target already exists: cp returned EEXIST (' + dest + ' already exists)', -17, 'cp')
      return undefined
    }
    host('fs_remove', { path: dest, recursive: false, force: false })
  }
  host('fs_copy', { from: src, to: dest, recursive: false })
  return undefined
}
const copyEntry = (from, to, options = {}) => {
  const dest = pathOf(to)
  const parent = dest.slice(0, dest.lastIndexOf('/'))
  if (parent !== '' && !fs.existsSync(parent)) host('fs_mkdir', { path: parent, recursive: true })
  return copyTree(from, to, options)
}
const copyLink = (src, dest, destStat, opts) => {
  let resolvedSrc = fs.readlinkSync(src)
  if (!resolvedSrc.startsWith('/')) resolvedSrc = cpResolve(src, resolvedSrc)
  const sourceIsDirectory = cpStatOrNull(resolvedSrc, true)?.isDirectory() === true
  if (destStat === null) return fs.symlinkSync(resolvedSrc, dest)
  if (!destStat.isSymbolicLink()) {
    if (!opts.force) return undefined
    throw cpError('EEXIST', "EEXIST: file already exists, symlink '" + resolvedSrc + "' -> '" + dest + "'", -17, 'symlink')
  }
  let resolvedDest = fs.readlinkSync(dest)
  if (!resolvedDest.startsWith('/')) resolvedDest = cpResolve(dest, resolvedDest)
  if (sourceIsDirectory && cpIsSubdir(resolvedSrc, resolvedDest)) throw cpInvalid('cannot copy ' + resolvedSrc + ' to a subdirectory of self ' + resolvedDest, dest)
  if (sourceIsDirectory && cpIsSubdir(resolvedDest, resolvedSrc)) throw cpError('ERR_FS_CP_SYMLINK_TO_SUBDIRECTORY', 'Cannot overwrite symlink in subdirectory of self: cp returned EINVAL (cannot overwrite ' + resolvedDest + ' with ' + resolvedSrc + ') ' + dest, -22, 'cp')
  host('fs_remove', { path: dest, recursive: false, force: false })
  return fs.symlinkSync(resolvedSrc, dest)
}
const statsFrom = (info) => {
  const atimeMs = info.atimeMs ?? info.mtimeMs
  const ctimeMs = info.ctimeMs ?? info.mtimeMs
  return {
    dev: 0,
    mode: info.mode,
    nlink: info.nlink ?? 1,
    uid: 0,
    gid: 0,
    rdev: 0,
    blksize: 4096,
    ino: info.ino ?? 0,
    size: info.size,
    blocks: info.blocks ?? 0,
    atimeMs,
    mtimeMs: info.mtimeMs,
    ctimeMs,
    birthtimeMs: ctimeMs,
    atime: new Date(atimeMs),
    mtime: new Date(info.mtimeMs),
    ctime: new Date(ctimeMs),
    birthtime: new Date(ctimeMs),
    isFile: () => info.type === 'file',
    isDirectory: () => info.type === 'directory',
    isSymbolicLink: () => info.type === 'symlink',
  }
}

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

const typeErrorCoded = (code, message) => {
  const error = new TypeError(message)
  error.code = code
  return error
}

const checkHighWaterMark = (value, name = 'highWaterMark') => {
  if (value === undefined || value === null || value === Infinity || (Number.isInteger(value) && value >= 0)) return
  throw typeErrorCoded('ERR_INVALID_ARG_VALUE', "The property 'options." + name + "' is invalid. Received " + (typeof value === 'string' ? "'" + value + "'" : String(value)))
}
const receivedText = (value) => (typeof value === 'string' ? "type string ('" + value + "')" : 'type ' + typeof value + ' (' + String(value) + ')')

const writeOptionMode = (mode) => {
  if (mode === undefined) return undefined
  if (typeof mode === 'number' && Number.isInteger(mode) && mode >= 0) return mode
  if (typeof mode === 'string' && /^[0-7]+$/.test(mode)) return parseInt(mode, 8)
  throw typeErrorCoded('ERR_INVALID_ARG_VALUE', "The argument 'mode' must be a 32-bit unsigned integer or an octal string. Received '" + String(mode) + "'")
}

const validateWriteOptions = (options) => {
  if (options.signal !== undefined) {
    if (typeof options.signal !== 'object' || options.signal === null) {
      throw typeErrorCoded('ERR_INVALID_ARG_TYPE', 'The "options.signal" property must be an instance of AbortSignal. Received ' + receivedText(options.signal))
    }
    if (options.signal.aborted) {
      const error = new Error('The operation was aborted')
      error.name = 'AbortError'
      error.code = 'ABORT_ERR'
      throw error
    }
  }
  if (options.flush !== undefined && typeof options.flush !== 'boolean') {
    throw typeErrorCoded('ERR_INVALID_ARG_TYPE', 'The "options.flush" property must be of type boolean. Received ' + receivedText(options.flush))
  }
}

const pathExists = (target) => {
  try {
    host('fs_stat', { path: target, follow: true })
    return true
  } catch (error) {
    if (error.code === 'ENOENT') return false
    throw error
  }
}

const writeFileSync = (value, data, options) => {
  const settings = typeof options === 'object' && options !== null ? options : {}
  validateWriteOptions(settings)
  const mode = writeOptionMode(settings.mode)
  const flag = settings.flag ?? 'w'
  const target = targetOf(value)
  const base64 = encodeBase64(toBytes(data, encodingOf(options)))
  if (flag.startsWith('r')) {
    host('fs_stat', { path: target, follow: true })
    host('fs_write_at', { path: target, position: 0, base64 })
    return
  }
  const existed = pathExists(target)
  if (flag.includes('x') && existed) throw coded('EEXIST', "EEXIST: file already exists, open '" + target + "'")
  host('fs_write', { path: target, base64, append: flag.startsWith('a') })
  if (mode !== undefined && !existed) host('fs_chmod', { path: target, mode })
}

const openSync = (value, flags = 'r') => {
  const target = pathOf(value)
  if (flags.startsWith('r')) {
    try {
      host('fs_stat', { path: target, follow: true })
    } catch (error) {
      throw openFailure(error.code, target)
    }
  } else host('fs_write', { path: target, base64: '', append: flags.startsWith('a') })
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

const fsConstants = { F_OK: 0, R_OK: 4, W_OK: 2, X_OK: 1, O_RDONLY: 0, O_WRONLY: 1, O_RDWR: 2, O_CREAT: 64, O_EXCL: 128, O_NOCTTY: 256, O_TRUNC: 512, O_APPEND: 1024, O_NONBLOCK: 2048, O_DSYNC: 4096, O_DIRECT: 16384, O_DIRECTORY: 65536, O_NOFOLLOW: 131072, O_NOATIME: 262144, O_SYNC: 1052672, COPYFILE_EXCL: 1 }

const openFailure = (code, target) => {
  const messages = {
    ENOENT: 'no such file or directory',
    EEXIST: 'file already exists',
    EBADF: 'bad file descriptor',
  }
  const error = nodeError(code, code + ': ' + messages[code] + ", open '" + target + "'")
  error.errno = { ENOENT: -2, EEXIST: -17, EBADF: -9 }[code]
  error.syscall = 'open'
  error.path = target
  return error
}

const readStreamFlags = {
  r: 'read', rs: 'read', sr: 'read', 'r+': 'readwrite', 'rs+': 'readwrite', 'sr+': 'readwrite',
  w: 'truncate', wx: 'truncate', xw: 'truncate', 'w+': 'truncate-readwrite', 'wx+': 'truncate-readwrite', 'xw+': 'truncate-readwrite',
  a: 'append', ax: 'append', xa: 'append', as: 'append', sa: 'append', 'a+': 'append-readwrite', 'ax+': 'append-readwrite', 'xa+': 'append-readwrite', 'as+': 'append-readwrite', 'sa+': 'append-readwrite',
}

const nodeReceived = (value) => {
  if (value === null) return 'null'
  if (value === undefined) return 'undefined'
  if (typeof value === 'function') return 'function ' + value.name
  if (typeof value === 'object') return 'an instance of ' + (value.constructor?.name ?? 'Object')
  return receivedText(value)
}

const rangeErrorCoded = (code, message) => {
  const error = new RangeError(message)
  error.code = code
  return error
}

const streamPosition = (name, value) => {
  if (value === undefined) return undefined
  if (typeof value !== 'number') throw typeErrorCoded('ERR_INVALID_ARG_TYPE', 'The "' + name + '" argument must be of type number. Received ' + nodeReceived(value))
  if (!Number.isInteger(value)) throw rangeErrorCoded('ERR_OUT_OF_RANGE', 'The value of "' + name + '" is out of range. It must be an integer. Received ' + String(value))
  if (value < 0 || value > Number.MAX_SAFE_INTEGER) throw rangeErrorCoded('ERR_OUT_OF_RANGE', 'The value of "' + name + '" is out of range. It must be >= 0 && <= ' + Number.MAX_SAFE_INTEGER + '. Received ' + String(value))
  return value
}

const addNumericalSeparator = (text) => {
  let res = ''
  let index = text.length
  const start = text[0] === '-' ? 1 : 0
  for (; index >= start + 4; index -= 3) res = '_' + text.slice(index - 3, index) + res
  return text.slice(0, index) + res
}

const abortedError = () => {
  const error = new Error('The operation was aborted')
  error.name = 'AbortError'
  error.code = 'ABORT_ERR'
  error.killed = null
  error.signal = null
  return error
}

const createReadStream = (value, options = {}) => {
  const settings = typeof options === 'string' ? { encoding: options } : options ?? {}
  const encoding = settings.encoding ?? null
  if (encoding !== null && stringDecoderEncodings[String(encoding).toLowerCase()] === undefined) {
    throw typeErrorCoded('ERR_INVALID_ARG_VALUE', "The argument 'encoding' is invalid encoding. Received '" + String(encoding) + "'")
  }
  const start = streamPosition('start', settings.start) ?? 0
  const end = settings.end === Infinity ? undefined : streamPosition('end', settings.end)
  if (end !== undefined && start > end) throw rangeErrorCoded('ERR_OUT_OF_RANGE', 'The value of "start" is out of range. It must be <= "end" (here: ' + end + '). Received ' + start)
  checkHighWaterMark(settings.highWaterMark)
  const highWaterMark = settings.highWaterMark ?? 65536
  const emptyRead = highWaterMark === 0 || (highWaterMark >= 4294967296 && highWaterMark < 1099511627776)
  const autoClose = settings.autoClose !== false
  const flag = settings.flags ?? 'r'
  const decoder = null
  const stream = new Readable({ encoding, autoDestroy: autoClose })
  stream.highWaterMark = highWaterMark
  stream.readableHighWaterMark = highWaterMark
  const target = pathOf(value)
  let failure = null
  if (settings.signal !== undefined) {
    if (typeof settings.signal !== 'object' || settings.signal === null || !('aborted' in settings.signal)) {
      throw typeErrorCoded('ERR_INVALID_ARG_TYPE', 'The "options.signal" property must be an instance of AbortSignal. Received ' + nodeReceived(settings.signal))
    }
    if (settings.signal.aborted) failure = abortedError()
    else {
      if (typeof settings.signal.addEventListener !== 'function') throw new TypeError('signal.addEventListener is not a function')
      settings.signal.addEventListener('abort', () => { if (!stream.destroyed) stream.destroy(abortedError()) }, { once: true })
    }
  }
  if (highWaterMark > Number.MAX_SAFE_INTEGER) {
    failure = rangeErrorCoded('ERR_OUT_OF_RANGE', 'The value of "size" is out of range. It must be >= 0 && <= ' + Number.MAX_SAFE_INTEGER + '. Received ' + addNumericalSeparator(String(highWaterMark)))
  } else if (highWaterMark >= 1099511627776) {
    failure = rangeErrorCoded('ERR_MEMORY_ALLOCATION_FAILED', 'Failed to allocate read buffer')
  }
  const mode = readStreamFlags[flag]
  if (mode === undefined) {
    failure = typeErrorCoded('ERR_INVALID_ARG_VALUE', "The argument 'flags' is invalid. Received '" + String(flag) + "'")
  }
  let bytes = new Uint8Array(0)
  if (failure === null) {
    const exists = pathExists(target)
    if (mode === undefined) {
    } else if (mode === 'read' || mode === 'readwrite') {
      if (!exists) failure = openFailure('ENOENT', target)
    } else if (flag.includes('x') && exists) {
      failure = openFailure('EEXIST', target)
    } else if (mode.startsWith('truncate')) {
      host('fs_write', { path: target, base64: '', append: false })
      if (mode === 'truncate') failure = openFailure('EBADF', target)
    } else if (mode.startsWith('append')) {
      if (!exists) host('fs_write', { path: target, base64: '', append: true })
      if (mode === 'append') failure = openFailure('EBADF', target)
    }
  }
  if (failure === null) {
    try {
      bytes = decodeBase64(host('fs_read', { path: target }).base64)
    } catch (error) {
      failure = openFailure('ENOENT', target)
    }
  }
  if (failure === null) {
    bytes = bytes.subarray(start, end === undefined ? bytes.length : Math.min(bytes.length, end + 1))
  }
  let offset = 0
  stream._read = () => {
    if (failure !== null) return stream.destroy(failure)
    if (emptyRead || offset >= bytes.length) {
      const rest = decoder !== null ? decoder.end() : ''
      if (rest.length > 0) stream.push(rest)
      return stream.push(null)
    }
    const chunk = bytes.subarray(offset, offset + highWaterMark)
    offset += highWaterMark
    if (decoder === null) return stream.push(wrapBytes(chunk))
    const text = decoder.write(chunk)
    if (text.length > 0) stream.push(text)
  }
  if (failure !== null) nextTick(() => stream.destroy(failure))
  nextTick(() => {
    if (failure === null) {
      stream.emit('open', 3)
      stream.emit('ready')
    }
  })
  return stream
}

const dirClosedError = () => {
  const error = new Error('Directory handle was closed')
  error.code = 'ERR_DIR_CLOSED'
  return error
}

class Dir {
  constructor(path, entries) {
    this.path = path
    this.entries = entries
    this.index = 0
    this.closed = false
  }
  async read() {
    if (this.closed) throw dirClosedError()
    if (this.index >= this.entries.length) return null
    const entry = this.entries[this.index]
    this.index += 1
    return entry
  }
  async close() {
    if (this.closed) throw dirClosedError()
    this.closed = true
  }
  async *[Symbol.asyncIterator]() {
    try {
      for (let entry = await this.read(); entry !== null; entry = await this.read()) yield entry
    } finally {
      if (!this.closed) await this.close()
    }
  }
}

const zeroStats = () => {
  const epoch = new Date(0)
  return {
    dev: 0, mode: 0, nlink: 0, uid: 0, gid: 0, rdev: 0, blksize: 0, ino: 0, size: 0, blocks: 0,
    atimeMs: 0, mtimeMs: 0, ctimeMs: 0, birthtimeMs: 0,
    atime: epoch, mtime: epoch, ctime: epoch, birthtime: epoch,
    isFile: () => false, isDirectory: () => false, isSymbolicLink: () => false,
  }
}

const fileWatchers = new Map()

const statOrZero = (target) => statOf(target, true, { throwIfNoEntry: false }) ?? zeroStats()

const sameStats = (left, right) => left.size === right.size && left.mtimeMs === right.mtimeMs && left.ino === right.ino && left.isFile() === right.isFile()

const watchFile = (filename, options, listener) => {
  const callback = typeof options === 'function' ? options : listener
  const settings = typeof options === 'function' ? {} : options ?? {}
  const target = pathOf(filename)
  let entry = fileWatchers.get(target)
  if (entry === undefined) {
    const initial = statOrZero(target)
    entry = { listeners: [], last: initial, pendingMissing: initial.ino === 0, timer: null }
    entry.timer = setInterval(() => {
      const curr = statOrZero(target)
      const changed = entry.pendingMissing || !sameStats(curr, entry.last)
      entry.pendingMissing = false
      if (!changed) return
      const prev = entry.last
      entry.last = curr
      for (const fn of [...entry.listeners]) fn(curr, prev)
    }, settings.interval ?? 5007)
    fileWatchers.set(target, entry)
  }
  if (typeof callback === 'function') entry.listeners.push(callback)
  return { ref: () => this, unref: () => this }
}

const unwatchFile = (filename, listener) => {
  const target = pathOf(filename)
  const entry = fileWatchers.get(target)
  if (entry === undefined) return
  entry.listeners = listener === undefined ? [] : entry.listeners.filter((fn) => fn !== listener)
  if (entry.listeners.length === 0) {
    clearInterval(entry.timer)
    fileWatchers.delete(target)
  }
}

const fs = {
  appendFileSync: (value, data, options) => writeFileSync(value, data, { ...(typeof options === "object" && options !== null ? options : {}), flag: "a" }),
  chmodSync: (value, mode) => host("fs_chmod", { path: pathOf(value), mode }),
  linkSync: (existing, value) => host("fs_link", { existing: pathOf(existing), path: pathOf(value) }),
  truncateSync: (value, length = 0) => host("fs_truncate", { path: pathOf(value), length }),
  accessSync: (value, mode = 0) => {
    if (!existsSync(value)) throw coded('ENOENT', "ENOENT: no such file or directory, access '" + pathOf(value) + "'")
    if ((mode & 1) !== 0 && (host('fs_stat', { path: pathOf(value), follow: true }).mode & 0o111) === 0) throw coded('EACCES', "EACCES: permission denied, access '" + pathOf(value) + "'")
  },
  closeSync,
  constants: fsConstants,
  copyFileSync: (from, to) => host('fs_copy', { from: pathOf(from), to: pathOf(to), recursive: false }),
  createReadStream,
  existsSync,
  lstatSync: (value, options) => statOf(value, false, options),
  mkdirSync: (value, options) => host('fs_mkdir', { path: pathOf(value), recursive: options?.recursive === true }).first,
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
  rmSync: (value, options) => void host('fs_remove', { path: pathOf(value), recursive: options?.recursive === true, force: options?.force === true }),
  statSync: (value, options) => statOf(value, true, options),
  symlinkSync: (target, value) => host('fs_symlink', { target: pathOf(target), path: pathOf(value) }),
  unlinkSync: (value) => host('fs_remove', { path: pathOf(value), recursive: false, force: false }),
  unwatchFile,
  watch: (path) => {
    const id = host('watch_start', { path: String(path) }).id
    return {
      next: (timeout = 1000) => host('watch_poll', { id, timeout }).events,
      close: () => host('watch_close', { id }),
    }
  },
  watchFile,
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
  cp: asAsync((from, to, options) => copyEntry(from, to, options)),
  link: asAsync((existing, value) => host('fs_link', { existing: pathOf(existing), path: pathOf(value) })),
  lstat: asAsync(fs.lstatSync),
  mkdir: asAsync(fs.mkdirSync),
  mkdtemp: asAsync(fs.mkdtempSync),
  open: asAsync(openHandle),
  opendir: fail('fs/promises.opendir'),
  readFile: asAsync(readFileSync),
  readdir: asAsync(fs.readdirSync),
  opendir: (value) => Promise.resolve().then(() => new Dir(pathOf(value), fs.readdirSync(value, { withFileTypes: true }))),
  realpath: asAsync(fs.realpathSync),
  readlink: asAsync(fs.readlinkSync),
  symlink: asAsync(fs.symlinkSync),
  rename: asAsync(fs.renameSync),
  rm: asAsync(fs.rmSync),
  stat: asAsync(fs.statSync),
  truncate: asAsync((value, length = 0) => host('fs_truncate', { path: pathOf(value), length })),
  unlink: asAsync(fs.unlinkSync),
  writeFile: asAsync(writeFileSync),
}

const cryptoBytes = (size) => decodeBase64(host('random_bytes', { n: size }).base64)

const randomBytes = (size, callback) => {
  const bytes = wrapBytes(cryptoBytes(size))
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

const createHash = (algorithm, options = {}) => {
  const chunks = []
  const request = { algorithm: String(algorithm).toLowerCase() }
  if (options?.outputLength !== undefined) {
    if (typeof options.outputLength !== 'number') throw typeErrorCoded('ERR_INVALID_ARG_TYPE', 'The "options.outputLength" property must be of type number. Received ' + receivedText(options.outputLength))
    if (!Number.isInteger(options.outputLength)) throw rangeErrorCoded('ERR_OUT_OF_RANGE', 'The value of "options.outputLength" is out of range. It must be an integer. Received ' + options.outputLength)
    if (options.outputLength < 0 || options.outputLength > 4294967295) throw rangeErrorCoded('ERR_OUT_OF_RANGE', 'The value of "options.outputLength" is out of range. It must be >= 0 && <= 4294967295. Received ' + options.outputLength)
  }
  const fixedDigestBytes = { md4: 16, md5: 16, sha1: 20, ripemd160: 20, sha224: 28, 'sha512-224': 28, 'sha3-224': 28, sha256: 32, 'sha512-256': 32, 'sha3-256': 32, blake2s256: 32, sha384: 48, 'sha3-384': 48, sha512: 64, 'sha3-512': 64, blake2b512: 64 }
  const xof = request.algorithm.startsWith('shake')
  if (options?.outputLength !== undefined && !xof && options.outputLength !== fixedDigestBytes[request.algorithm]) {
    const error = new Error('error:030000B2:digital envelope routines::not XOF or invalid length')
    error.code = 'ERR_OSSL_EVP_NOT_XOF_OR_INVALID_LENGTH'
    throw error
  }
  if (options?.outputLength !== undefined) request.output_length = Number(options.outputLength)
  let finalized = false
  const hash = {
    update(data, encoding) {
      if (finalized) throw nodeError('ERR_CRYPTO_HASH_FINALIZED', 'Digest already called')
      if (typeof data !== 'string' && !ArrayBuffer.isView(data)) throw typeErrorCoded('ERR_INVALID_ARG_TYPE', 'The "data" argument must be of type string or an instance of Buffer, TypedArray, or DataView. Received ' + receivedText(data))
      chunks.push(toBytes(data, encoding))
      return hash
    },
    digest(encoding) {
      if (finalized) throw nodeError('ERR_CRYPTO_HASH_FINALIZED', 'Digest already called')
      finalized = true
      const reply = host('hash_digest', { ...request, base64: encodeBase64(concatBytes(chunks)) })
      const bytes = decodeHex(reply.hex)
      return encoding === undefined ? wrapBytes(bytes) : fromBytes(bytes, encoding)
    },
  }
  return hash
}

const crypto = { createHash, randomBytes, randomUUID }

class FxEmitter {
  constructor() { this.registry = new Map() }
  addEntry(event, listener, once, prepend) {
    if (typeof listener !== 'function') throw typeErrorCoded('ERR_INVALID_ARG_TYPE', 'The "listener" argument must be of type function. Received ' + receivedText(listener))
    if (this.registry.has('newListener')) this.emit('newListener', event, listener)
    const entry = { original: listener, listener: null }
    entry.listener = once ? (...args) => {
      this.removeEntry(event, entry)
      return listener.apply(this, args)
    } : listener
    const list = this.registry.get(event) ?? []
    if (prepend) list.unshift(entry)
    else list.push(entry)
    this.registry.set(event, list)
    if (!prepend) this.listenerAdded(event)
    return this
  }
  removeEntry(event, entry) {
    const list = this.registry.get(event)
    if (list === undefined) return
    const index = list.indexOf(entry)
    if (index < 0) return
    list.splice(index, 1)
    if (list.length === 0) this.registry.delete(event)
    if (this.registry.has('removeListener')) this.emit('removeListener', event, entry.original)
    this.listenerRemoved(event)
  }
  listenerAdded() {}
  listenerRemoved() {}
  addListener(event, listener) { return this.addEntry(event, listener, false, false) }
  on(event, listener) { return this.addEntry(event, listener, false, false) }
  once(event, listener) { return this.addEntry(event, listener, true, false) }
  prependListener(event, listener) { return this.addEntry(event, listener, false, true) }
  prependOnceListener(event, listener) { return this.addEntry(event, listener, true, true) }
  removeListener(event, listener) {
    const list = this.registry.get(event) ?? []
    for (let index = list.length - 1; index >= 0; index -= 1) {
      if (list[index].original === listener) {
        this.removeEntry(event, list[index])
        break
      }
    }
    return this
  }
  off(event, listener) { return this.removeListener(event, listener) }
  removeAllListeners(event) {
    if (event === undefined) {
      for (const name of [...this.registry.keys()]) if (name !== 'removeListener') this.removeAllListeners(name)
      this.removeAllListeners('removeListener')
      return this
    }
    const list = this.registry.get(event) ?? []
    if (this.registry.has('removeListener')) {
      for (const entry of [...list].reverse()) this.removeEntry(event, entry)
    } else {
      this.registry.delete(event)
    }
    this.listenerRemoved(event)
    return this
  }
  listeners(event) { return (this.registry.get(event) ?? []).map((entry) => entry.original) }
  rawListeners(event) { return (this.registry.get(event) ?? []).map((entry) => entry.listener) }
  listenerCount(event) { return (this.registry.get(event) ?? []).length }
  eventNames() { return [...this.registry.keys()].filter((name) => this.registry.get(name).length > 0) }
  setMaxListeners(count) {
    this.maxListeners = count
    return this
  }
  getMaxListeners() { return this.maxListeners ?? 10 }
  emit(event, ...args) {
    const list = this.registry.get(event)
    if (list === undefined || list.length === 0) return false
    for (const entry of [...list]) entry.listener.apply(this, args)
    return true
  }
}

const nodeError = (code, message) => {
  const error = new Error(message)
  error.code = code
  return error
}

const nextTick = (callback) => queueMicrotask(callback)

class Readable extends FxEmitter {
  constructor(options = {}) {
    super()
    if (typeof options.read === 'function') this._read = options.read
    this.objectMode = options.objectMode ?? false
    this.autoDestroy = options.autoDestroy ?? true
    checkHighWaterMark(options.highWaterMark)
    this.highWaterMark = options.highWaterMark ?? (this.objectMode ? 16 : 65536)
    this.readableHighWaterMark = this.highWaterMark
    if (options.encoding !== undefined && options.encoding !== null && stringDecoderEncodings[String(options.encoding).toLowerCase()] === undefined) {
      throw typeErrorCoded('ERR_UNKNOWN_ENCODING', 'Unknown encoding: ' + String(options.encoding))
    }
    this.encoding = options.encoding ?? null
    this.decoder = this.encoding !== null ? new StringDecoder(this.encoding) : null
    this.buffer = []
    this.length = 0
    this.flowing = null
    this.ended = false
    this.endEmitted = false
    this.reading = false
    this.sync = false
    this.needReadable = false
    this.emittedReadable = false
    this.readableListening = false
    this.resumeScheduled = false
    this.paused = false
    this.destroyed = false
    this.errored = null
    this.pipes = []
    this.maybeReadPending = false
  }
  get readableEncoding() {
    return this.encoding
  }
  get readableLength() {
    return this.length
  }
  get readableFlowing() {
    return this.flowing
  }
  get readableEnded() {
    return this.endEmitted
  }
  _read() {
    this.destroy(nodeError('ERR_METHOD_NOT_IMPLEMENTED', 'The _read() method is not implemented'))
  }
  listenerAdded(event) {
    if (event === 'data') {
      if (this.flowing !== false) this.resume()
    } else if (event === 'readable' && !this.endEmitted && !this.readableListening) {
      this.readableListening = true
      this.needReadable = true
      this.flowing = false
      this.emittedReadable = false
      if (this.length > 0) this.emitReadable()
      else if (!this.reading) nextTick(() => this.read(0))
    }
  }
  listenerRemoved(event) {
    if (event === 'readable') nextTick(() => this.updateReadableListening())
  }
  updateReadableListening() {
    this.readableListening = this.listenerCount('readable') > 0
    if (this.resumeScheduled && this.paused === false) this.flowing = true
    else if (this.listenerCount('data') > 0) this.resume()
    else if (!this.readableListening) this.flowing = null
  }
  push(chunk, encoding) {
    return this.readableAddChunk(chunk, encoding, false)
  }
  unshift(chunk, encoding) {
    const accepted = this.readableAddChunk(chunk, encoding, true)
    return accepted === false ? false : !this.ended
  }
  isPaused() {
    return this.paused === true
  }
  readableAddChunk(chunk, encoding, addToFront) {
    if (chunk === null) {
      this.reading = false
      this.onEofChunk()
      return false
    }
    let value = chunk
    if (!this.objectMode) {
      if (typeof value === 'string') {
        const bytes = toBytes(value, encoding ?? 'utf8')
        value = addToFront && this.encoding !== null ? fromBytes(bytes, this.encoding) : wrapBytes(bytes)
      }
      if (value.length === 0) {
        if (!addToFront) this.reading = false
        return this.needMoreData()
      }
    } else if (this.decoder !== null && typeof value === 'object' && value !== null && !ArrayBuffer.isView(value)) {
      throw typeErrorCoded('ERR_INVALID_ARG_TYPE', 'The "buf" argument must be an instance of Buffer, TypedArray, or DataView. Received ' + nodeReceived(value))
    }
    if (addToFront && this.decoder !== null && !this.objectMode && typeof value !== 'string') value = fromBytes(value, 'utf8')
    if (addToFront) {
      if (this.endEmitted) {
        nextTick(() => this.emit('error', nodeError('ERR_STREAM_UNSHIFT_AFTER_END_EVENT', 'stream.unshift() after end event')))
        return false
      }
      this.addChunk(value, true)
      return true
    }
    if (this.ended) {
      const error = nodeError('ERR_STREAM_PUSH_AFTER_EOF', 'stream.push() after EOF')
      this.errored = error
      nextTick(() => {
        this.emit('error', error)
        if (this.autoDestroy) {
          this.destroyed = true
          this.emit('close')
        }
      })
      return false
    }
    this.reading = false
    if (this.decoder !== null && !this.objectMode) {
      value = this.decoder.write(value)
      if (value.length === 0) return this.needMoreData()
    }
    this.addChunk(value, false)
    return this.needMoreData()
  }
  needMoreData() {
    return !this.ended && (this.needReadable || this.length < this.highWaterMark || this.length === 0)
  }
  addChunk(value, addToFront) {
    const size = this.objectMode ? 1 : value.length
    if (!addToFront && this.flowing && this.length === 0 && !this.sync && this.listenerCount('data') > 0) {
      this.emit('data', value)
    } else {
      this.length += size
      if (addToFront) this.buffer.unshift(value)
      else this.buffer.push(value)
      if (this.needReadable) this.emitReadable()
    }
    this.maybeReadMore()
  }
  onEofChunk() {
    if (this.ended) return
    if (this.decoder !== null) {
      const rest = this.decoder.end()
      if (rest.length > 0) {
        this.buffer.push(rest)
        this.length += rest.length
      }
    }
    this.ended = true
    if (this.sync) {
      this.emitReadable()
    } else {
      this.needReadable = false
      this.emittedReadable = true
      this.emitReadable_()
    }
  }
  emitReadable() {
    this.needReadable = false
    if (!this.emittedReadable) {
      this.emittedReadable = true
      nextTick(() => this.emitReadable_())
    }
  }
  emitReadable_() {
    if (!this.destroyed && (this.length > 0 || this.ended)) {
      this.emit('readable')
      this.emittedReadable = false
    }
    this.needReadable = !this.flowing && !this.ended && this.length <= this.highWaterMark
    this.flow()
  }
  maybeReadMore() {
    if (this.maybeReadPending) return
    this.maybeReadPending = true
    nextTick(() => {
      while (!this.reading && !this.ended && (this.length < this.highWaterMark || (this.flowing && this.length === 0))) {
        const before = this.length
        this.read(0)
        if (this.length === before) break
      }
      this.maybeReadPending = false
    })
  }
  howMuchToRead(n) {
    if (n <= 0 || (this.length === 0 && this.ended)) return 0
    if (this.objectMode) return 1
    if (Number.isNaN(n)) {
      if (this.flowing && this.buffer.length > 0) return this.buffer[0].length
      return this.length
    }
    if (n <= this.length) return n
    return this.ended ? this.length : 0
  }
  takeFromBuffer(amount) {
    if (this.length === 0) return null
    if (this.objectMode) {
      this.length -= 1
      return this.buffer.shift()
    }
    const parts = []
    let need = amount
    while (need > 0 && this.buffer.length > 0) {
      const head = this.buffer[0]
      if (head.length <= need) {
        parts.push(head)
        this.buffer.shift()
        need -= head.length
        this.length -= head.length
      } else {
        parts.push(typeof head === 'string' ? head.slice(0, need) : head.subarray(0, need))
        this.buffer[0] = typeof head === 'string' ? head.slice(need) : head.subarray(need)
        this.length -= need
        need = 0
      }
    }
    if (parts.length === 0) return null
    if (typeof parts[0] === 'string') return parts.join('')
    return parts.length === 1 ? parts[0] : wrapBytes(concatBytes(parts))
  }
  read(n) {
    let amount = n === undefined ? NaN : Number.isInteger(n) ? n : Number.parseInt(n, 10)
    const requested = amount
    if (amount !== 0) this.emittedReadable = false
    if (amount === 0 && this.needReadable && (this.length >= this.highWaterMark || this.ended)) {
      if (this.length === 0 && this.ended) this.endReadable()
      else this.emitReadable()
      return null
    }
    amount = this.howMuchToRead(amount)
    if (amount === 0 && this.ended) {
      if (this.length === 0) this.endReadable()
      return null
    }
    let doRead = this.needReadable
    if (this.length === 0 || this.length - amount < this.highWaterMark) doRead = true
    if (this.ended || this.reading || this.destroyed) {
      doRead = false
    } else if (doRead) {
      this.reading = true
      this.sync = true
      if (this.length === 0) this.needReadable = true
      this._read(this.highWaterMark)
      this.sync = false
      if (!this.reading) amount = this.howMuchToRead(requested)
    }
    const ret = amount > 0 ? this.takeFromBuffer(amount) : null
    if (ret === null) {
      this.needReadable = this.length <= this.highWaterMark
      amount = 0
    }
    if (this.length === 0) {
      if (!this.ended) this.needReadable = true
      if (requested !== amount && this.ended) this.endReadable()
    }
    if (ret !== null) this.emit('data', ret)
    return ret
  }
  endReadable() {
    if (this.endEmitted) return
    this.ended = true
    nextTick(() => this.endReadableNT())
  }
  endReadableNT() {
    if (!this.endEmitted && this.length === 0 && this.errored === null) {
      this.endEmitted = true
      this.emit('end')
      if (this.autoDestroy) this.destroy()
    }
  }
  flow() {
    while (this.flowing && !this.destroyed && this.read() !== null);
  }
  resume() {
    if (!this.flowing) {
      this.flowing = !this.readableListening
      if (!this.resumeScheduled) {
        this.resumeScheduled = true
        nextTick(() => this.resume_())
      }
    }
    this.paused = false
    return this
  }
  resume_() {
    if (!this.reading) this.read(0)
    this.resumeScheduled = false
    this.emit('resume')
    this.flow()
    if (this.flowing && !this.reading) this.read(0)
  }
  pause() {
    if (this.flowing !== false) {
      this.flowing = false
      this.emit('pause')
    }
    this.paused = true
    return this
  }
  setEncoding(encoding) {
    if (stringDecoderEncodings[String(encoding).toLowerCase()] === undefined) throw typeErrorCoded('ERR_UNKNOWN_ENCODING', 'Unknown encoding: ' + String(encoding))
    const decoder = new StringDecoder(encoding)
    this.decoder = decoder
    this.encoding = String(encoding).toLowerCase() === 'utf-8' ? 'utf8' : encoding
    let content = ''
    for (const part of this.buffer) content += typeof part === 'string' ? part : decoder.write(part)
    this.buffer = content.length > 0 ? [content] : []
    this.length = content.length
    return this
  }
  pipe(destination) {
    const source = this
    const entry = { destination, source: this }
    entry.onData = (chunk) => {
      if (destination.write(chunk) === false) source.pause()
    }
    entry.onDrain = () => source.resume()
    entry.onEnd = () => destination.end()
    entry.onError = (error) => {
      cleanup(entry)
      if (destination.listenerCount('error') === 0) destination.emit('error', error)
    }
    entry.onClose = () => cleanup(entry)
    entry.onFinish = () => cleanup(entry)
    this.pipes.push(entry)
    destination.emit('pipe', source)
    this.on('data', entry.onData)
    this.once('end', entry.onEnd)
    destination.on('drain', entry.onDrain)
    destination.prependListener('error', entry.onError)
    destination.once('close', entry.onClose)
    destination.once('finish', entry.onFinish)
    if (destination.writableNeedDrain === true) this.pause()
    else if (!this.flowing) this.resume()
    return destination
  }
  unpipe(destination) {
    if (this.pipes.length === 0) return this
    if (destination === undefined) {
      const entries = this.pipes
      this.pipes = []
      this.pause()
      for (const entry of entries) releasePipe(this, entry)
      return this
    }
    const entry = this.pipes.find((item) => item.destination === destination)
    if (entry === undefined) return this
    cleanup(entry)
    return this
  }
  wrap(stream) {
    let paused = false
    this._read = () => {
      if (paused) {
        paused = false
        stream.resume()
      }
    }
    stream.on('data', (chunk) => {
      if (!this.push(chunk) && typeof stream.pause === 'function') {
        paused = true
        stream.pause()
      }
    })
    stream.on('end', () => this.push(null))
    stream.on('error', (error) => this.destroy(error))
    stream.on('close', () => this.destroy())
    for (const key in stream) {
      if (this[key] === undefined && typeof stream[key] === 'function') this[key] = stream[key].bind(stream)
    }
    return this
  }
  destroy(error) {
    if (this.destroyed) return this
    this.destroyed = true
    nextTick(() => {
      if (error) this.emit('error', error)
      if (this.autoDestroy) this.emit('close')
    })
    return this
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

const releasePipe = (source, entry) => {
  source.removeListener('data', entry.onData)
  source.removeListener('end', entry.onEnd)
  entry.destination.removeListener('drain', entry.onDrain)
  entry.destination.removeListener('error', entry.onError)
  entry.destination.removeListener('close', entry.onClose)
  entry.destination.removeListener('finish', entry.onFinish)
  entry.destination.emit('unpipe', source)
}

const cleanup = (entry) => {
  const source = entry.source
  source.pipes = source.pipes.filter((item) => item !== entry)
  if (source.pipes.length === 0) source.pause()
  releasePipe(source, entry)
}

class Writable extends FxEmitter {
  constructor(options = {}) {
    super()
    if (typeof options.write === 'function') this.writeImpl = options.write
    if (typeof options.writev === 'function') this.writevImpl = options.writev
    this.objectMode = options.objectMode ?? false
    checkHighWaterMark(options.highWaterMark)
    this.highWaterMark = options.highWaterMark ?? (this.objectMode ? 16 : 65536)
    this.decodeStrings = options.decodeStrings !== false
    this.defaultEncoding = options.defaultEncoding ?? 'utf8'
    this.autoDestroy = options.autoDestroy ?? true
    this.chunks = []
    this.length = 0
    this.buffered = []
    this.writing = false
    this.current = null
    this.sync = false
    this.corked = 0
    this.needDrain = false
    this.pending = 0
    this.ending = false
    this.finished = false
    this.destroyed = false
    this.errored = null
    this.finishCallbacks = []
  }
  get writable() {
    return !this.ending && !this.destroyed
  }
  get writableEnded() {
    return this.ending
  }
  get writableFinished() {
    return this.finished
  }
  get writableCorked() {
    return this.corked
  }
  get writableLength() {
    return this.length
  }
  get writableHighWaterMark() {
    return this.highWaterMark
  }
  get writableNeedDrain() {
    return this.needDrain && !this.destroyed
  }
  setDefaultEncoding(encoding) {
    if (stringDecoderEncodings[String(encoding).toLowerCase()] === undefined) throw typeErrorCoded('ERR_UNKNOWN_ENCODING', 'Unknown encoding: ' + String(encoding))
    this.defaultEncoding = String(encoding).toLowerCase()
    return this
  }
  write(chunk, encoding, callback) {
    const done = typeof encoding === 'function' ? encoding : callback
    const enc = typeof encoding === 'string' ? encoding : this.defaultEncoding
    let value = chunk
    let valueEncoding = typeof chunk === 'string' ? enc : 'buffer'
    if (!this.objectMode && typeof value === 'string' && this.decodeStrings) {
      value = wrapBytes(toBytes(value, enc))
      valueEncoding = 'buffer'
    }
    if (this.ending) {
      this.writeAfterEnd(done)
      return false
    }
    if (this.destroyed) {
      nextTick(() => {
        if (done) done(nodeError('ERR_STREAM_DESTROYED', 'Cannot call write after a stream was destroyed'))
      })
      return false
    }
    const size = this.objectMode ? 1 : value.length ?? 1
    this.length += size
    const ret = this.length < this.highWaterMark
    if (!ret) this.needDrain = true
    this.pending += 1
    const entry = { chunk: value, encoding: valueEncoding, callback: done, size }
    if (this.writing || this.corked > 0 || this.errored !== null) this.buffered.push(entry)
    else this.doWrite(entry)
    return ret && this.errored === null && !this.destroyed
  }
  writeAfterEnd(done) {
    const error = nodeError('ERR_STREAM_WRITE_AFTER_END', 'write after end')
    nextTick(() => {
      if (done) done(error)
    })
    this.destroy(error)
  }
  doWrite(entry) {
    this.writing = true
    this.current = [entry]
    this.sync = true
    const onwrite = (error) => this.onwrite([entry], error)
    if (this.writeImpl) this.writeImpl.call(this, entry.chunk, entry.encoding, onwrite)
    else {
      this.chunks.push(entry.chunk)
      onwrite()
    }
    this.sync = false
  }
  onwrite(entries, error) {
    if (this.current === null || this.current[0] !== entries[0]) return
    this.current = null
    this.writing = false
    for (const entry of entries) this.length -= entry.size
    const wasSync = this.sync
    if (error) {
      this.errored = error
      const callbacks = () => {
        for (const entry of entries) {
          this.pending -= 1
          if (entry.callback) entry.callback(error)
        }
      }
      if (wasSync) nextTick(callbacks)
      else callbacks()
      this.errorBuffer()
      this.destroy(error)
      return
    }
    for (const entry of entries) this.pending -= 1
    if (this.buffered.length > 0) this.clearBuffer()
    const callbacks = () => {
      for (const entry of entries) {
        if (entry.callback) entry.callback(null)
      }
      if (this.destroyed) this.errorBuffer()
      if (!this.ending && !this.destroyed && this.length === 0 && this.needDrain) {
        this.needDrain = false
        this.emit('drain')
      }
      this.maybeFinish()
    }
    if (wasSync) nextTick(callbacks)
    else callbacks()
  }
  clearBuffer() {
    if (this.corked > 0 || this.writing || this.errored !== null || this.destroyed) return
    if (this.buffered.length === 0) return
    if (this.buffered.length > 1 && this.writevImpl) {
      const batch = this.buffered.splice(0)
      this.writing = true
      this.current = batch
      this.sync = true
      const chunks = batch.map((entry) => ({ chunk: entry.chunk, encoding: entry.encoding }))
      this.writevImpl.call(this, chunks, (error) => this.onwrite(batch, error))
      this.sync = false
      return
    }
    this.doWrite(this.buffered.shift())
  }
  errorBuffer() {
    if (this.writing) return
    const error = this.errored ?? nodeError('ERR_STREAM_DESTROYED', 'Cannot call write after a stream was destroyed')
    const pendingEntries = this.buffered.splice(0)
    for (const entry of pendingEntries) {
      this.pending -= 1
      this.length -= entry.size
      if (entry.callback) entry.callback(error)
    }
  }
  cork() {
    this.corked += 1
  }
  uncork() {
    if (this.corked === 0) return
    this.corked -= 1
    if (this.corked === 0) this.clearBuffer()
  }
  end(chunk, encoding, callback) {
    const done = typeof chunk === 'function' ? chunk : typeof encoding === 'function' ? encoding : callback
    if (chunk !== undefined && chunk !== null && typeof chunk !== 'function') this.write(chunk, typeof encoding === 'string' ? encoding : undefined)
    if (this.corked > 0) {
      this.corked = 1
      this.uncork()
    }
    this.ending = true
    if (done) {
      if (this.finished) nextTick(() => done())
      else this.finishCallbacks.push(done)
    }
    this.maybeFinish()
    return this
  }
  maybeFinish() {
    const needFinish = this.ending && !this.destroyed && this.errored === null && this.length === 0 && this.buffered.length === 0 && !this.finished && !this.writing && this.pending === 0
    if (needFinish) nextTick(() => this.finishStream())
  }
  finishStream() {
    if (this.finished) return
    this.finished = true
    for (const callback of this.finishCallbacks.splice(0)) callback()
    this.emit('finish')
    if (this.autoDestroy) this.destroy()
  }
  destroy(error) {
    if (this.destroyed) return this
    this.destroyed = true
    if (!this.writing) this.errorBuffer()
    nextTick(() => {
      if (error) this.emit('error', error)
      this.emit('close')
    })
    return this
  }
}

class PassThrough extends Readable {
  constructor(options = {}) {
    checkHighWaterMark(options.highWaterMark, 'readableHighWaterMark')
    super(options)
    this._read = () => {}
  }
  write(chunk) {
    return this.push(chunk)
  }
  end(chunk) {
    if (chunk !== undefined && chunk !== null) this.push(chunk)
    this.push(null)
    nextTick(() => this.emit('finish'))
    return this
  }
}

const pipeline = (...streams) => {
  const callback = typeof streams[streams.length - 1] === 'function' ? streams.pop() : () => {}
  for (let index = 0; index < streams.length - 1; index += 1) streams[index].pipe(streams[index + 1])
  let error
  let open = streams.length
  let called = false
  const finish = () => {
    if (called) return
    called = true
    callback(error)
  }
  for (const current of streams) {
    current.on('error', (cause) => {
      if (error === undefined) error = cause
      for (const other of streams) if (other !== current && !other.destroyed) other.destroy()
    })
    current.on('close', () => {
      open -= 1
      if (open === 0) finish()
    })
  }
  return streams[streams.length - 1]
}

const eventsOnce = (emitter, name) => new Promise((resolve, reject) => {
  const onEvent = (...args) => {
    emitter.removeListener('error', onError)
    resolve(args)
  }
  const onError = (error) => {
    emitter.removeListener(name, onEvent)
    reject(error)
  }
  emitter.once(name, onEvent)
  if (name !== 'error') emitter.once('error', onError)
})

const eventsModule = { EventEmitter: FxEmitter, once: eventsOnce }

const stream = { PassThrough, Readable, Writable, Transform: PassThrough, pipeline }

const compareBytes = (left, right) => {
  const shared = Math.min(left.length, right.length)
  for (let index = 0; index < shared; index += 1) {
    if (left[index] !== right[index]) return left[index] < right[index] ? -1 : 1
  }
  return left.length === right.length ? 0 : left.length < right.length ? -1 : 1
}

class FxBuffer extends Uint8Array {
  toString(encoding, start = 0, end = this.length) {
    return fromBytes(this.subarray(start, end), encoding ?? 'utf8')
  }
  toJSON() {
    return { type: 'Buffer', data: Array.from(this) }
  }
  equals(other) {
    return compareBytes(this, other) === 0
  }
  compare(other) {
    return compareBytes(this, other)
  }
  copy(target, targetStart = 0, sourceStart = 0, sourceEnd = this.length) {
    const source = this.subarray(sourceStart, sourceEnd)
    const count = Math.min(source.length, target.length - targetStart)
    if (count <= 0) return 0
    target.set(source.subarray(0, count), targetStart)
    return count
  }
  write(text, offset = 0, length = this.length - offset, encoding = 'utf8') {
    const bytes = toBytes(text, typeof offset === 'string' ? offset : encoding)
    const at = typeof offset === 'number' ? offset : 0
    const count = Math.min(bytes.length, this.length - at, length)
    this.set(bytes.subarray(0, count), at)
    return count
  }
  slice(start, end) {
    return this.subarray(start, end)
  }
  readUIntBE(offset, byteLength) {
    let value = 0
    for (let index = 0; index < byteLength; index += 1) value = value * 256 + this[offset + index]
    return value
  }
  readUIntLE(offset, byteLength) {
    let value = 0
    for (let index = byteLength - 1; index >= 0; index -= 1) value = value * 256 + this[offset + index]
    return value
  }
  view() {
    return new DataView(this.buffer, this.byteOffset, this.byteLength)
  }
}

const numericAccessors = {
  UInt8: ['Uint8', 1], Int8: ['Int8', 1],
  UInt16BE: ['Uint16', 2, false], UInt16LE: ['Uint16', 2, true], Int16BE: ['Int16', 2, false], Int16LE: ['Int16', 2, true],
  UInt32BE: ['Uint32', 4, false], UInt32LE: ['Uint32', 4, true], Int32BE: ['Int32', 4, false], Int32LE: ['Int32', 4, true],
  FloatBE: ['Float32', 4, false], FloatLE: ['Float32', 4, true], DoubleBE: ['Float64', 8, false], DoubleLE: ['Float64', 8, true],
}
for (const [name, [kind, size, little]] of Object.entries(numericAccessors)) {
  const littleEndian = little === true
  FxBuffer.prototype['read' + name] = function read(offset = 0) {
    return this.view()['get' + kind](offset, littleEndian)
  }
  FxBuffer.prototype['write' + name] = function write(value, offset = 0) {
    this.view()['set' + kind](offset, value, littleEndian)
    return offset + size
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
Buffer.alloc = (size, fill = 0, encoding) => {
  const bytes = new Uint8Array(size)
  const pattern = typeof fill === 'string' ? toBytes(fill, encoding) : Uint8Array.of(fill & 0xff)
  if (fill !== 0 && pattern.length > 0) for (let index = 0; index < size; index += 1) bytes[index] = pattern[index % pattern.length]
  return wrapBytes(bytes)
}
Buffer.byteLength = (value, encoding) => (typeof value === 'string' ? toBytes(value, encoding).length : value.byteLength)
Buffer.isBuffer = (value) => value instanceof FxBuffer
Buffer.concat = (list, totalLength) => {
  const bytes = concatBytes(list)
  if (totalLength === undefined) return wrapBytes(bytes)
  const exact = new Uint8Array(totalLength)
  exact.set(bytes.subarray(0, totalLength))
  return wrapBytes(exact)
}

const buffer = { Buffer, constants: { MAX_LENGTH: Number.MAX_SAFE_INTEGER, MAX_STRING_LENGTH: 536870888 } }

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

const deepStrictKeys = (object) => [
  ...Object.keys(object),
  ...Object.getOwnPropertySymbols(object).filter((symbol) => Object.prototype.propertyIsEnumerable.call(object, symbol)),
]

const deepStrictEqualWith = (left, right, seen) => {
  if (Object.is(left, right)) return true
  if (typeof left !== 'object' || typeof right !== 'object' || left === null || right === null) return false
  if (Object.getPrototypeOf(left) !== Object.getPrototypeOf(right)) return false
  if (seen.get(left)?.has(right)) return true
  seen.set(left, (seen.get(left) ?? new Set()).add(right))
  if (left instanceof Date && left.getTime() !== right.getTime()) return false
  if (left instanceof RegExp && (left.source !== right.source || left.flags !== right.flags)) return false
  if (left instanceof Error && (left.name !== right.name || left.message !== right.message)) return false
  if ((left instanceof Number || left instanceof String || left instanceof Boolean) && !Object.is(left.valueOf(), right.valueOf())) return false
  if (left instanceof ArrayBuffer && !deepStrictEqualWith(new Uint8Array(left), new Uint8Array(right), seen)) return false
  if (left instanceof Map) {
    if (left.size !== right.size) return false
    for (const [key, value] of left) if (!right.has(key) || !deepStrictEqualWith(value, right.get(key), seen)) return false
  }
  if (left instanceof Set) {
    if (left.size !== right.size) return false
    for (const value of left) if (!right.has(value) && ![...right].some((other) => deepStrictEqualWith(value, other, seen))) return false
  }
  const leftKeys = deepStrictKeys(left)
  if (leftKeys.length !== deepStrictKeys(right).length) return false
  return leftKeys.every((key) => Object.prototype.propertyIsEnumerable.call(right, key) && deepStrictEqualWith(left[key], right[key], seen))
}

const isDeepStrictEqual = (left, right) => deepStrictEqualWith(left, right, new Map())

const parseEnv = (content) => {
  const out = {}
  const text = String(content).replace(/\r\n/g, '\n')
  for (const match of text.matchAll(/(?:^|^)\s*(?:export\s+)?([\w.-]+)(?:\s*=\s*?|:\s+?)(\s*'(?:\\'|[^'])*'|\s*"(?:\\"|[^"])*"|\s*`(?:\\`|[^`])*`|[^#\r\n]+)?\s*(?:#.*)?(?:$|$)/gm)) {
    const raw = (match[2] ?? '').trim()
    const quoted = /^(['"`])([\s\S]*)\1$/.exec(raw)
    let value = quoted ? quoted[2] : raw
    if (quoted && quoted[1] === '"') value = value.replace(/\\n/g, '\n').replace(/\\r/g, '\r')
    out[match[1]] = value
  }
  return out
}

const promisify = (operation) => (...args) => new Promise((resolve, reject) => {
  operation(...args, (error, value) => (error ? reject(error) : resolve(value)))
})

const parseArgsError = (code, message) => {
  const error = new TypeError(message)
  error.code = code
  return error
}

const parseArgsOptionOf = (options, name) => (Object.prototype.hasOwnProperty.call(options, name) ? options[name] : undefined)

const parseArgsLongFor = (options, short) => {
  for (const name of Object.keys(options)) if (options[name].short === short) return name
  return short
}

const parseArgsIsShortGroup = (arg, options) => arg.length > 2 && arg[0] === '-' && arg[1] !== '-' && parseArgsOptionOf(options, parseArgsLongFor(options, arg[1]))?.type !== 'string'

const parseArgsIsShortValue = (arg, options) => arg.length > 2 && arg[0] === '-' && arg[1] !== '-' && parseArgsOptionOf(options, parseArgsLongFor(options, arg[1]))?.type === 'string'

const parseArgsToken = (name, rawName, index, value, inlineValue) => {
  const token = { kind: 'option', name, rawName, index }
  if (value !== undefined) token.value = value
  if (inlineValue !== undefined) token.inlineValue = inlineValue
  return token
}

const parseArgsTokenize = (args, options, allowNegative) => {
  const tokens = []
  const remaining = [...args]
  let index = -1
  let groupCount = 0
  while (remaining.length > 0) {
    const arg = remaining.shift()
    const next = remaining[0]
    if (groupCount > 0) groupCount -= 1
    else index += 1
    if (arg === '--') {
      tokens.push({ kind: 'option-terminator', index })
      for (const rest of remaining) {
        index += 1
        tokens.push({ kind: 'positional', index, value: rest })
      }
      break
    }
    if (arg.length === 2 && arg[0] === '-' && arg[1] !== '-') {
      const name = parseArgsLongFor(options, arg[1])
      let value
      let inlineValue
      if (parseArgsOptionOf(options, name)?.type === 'string' && next !== undefined) {
        value = remaining.shift()
        inlineValue = false
      }
      tokens.push(parseArgsToken(name, arg, index, value, inlineValue))
      if (value !== undefined) index += 1
      continue
    }
    if (parseArgsIsShortGroup(arg, options)) {
      const expanded = []
      for (let at = 1; at < arg.length; at += 1) {
        const short = arg[at]
        if (parseArgsOptionOf(options, parseArgsLongFor(options, short))?.type !== 'string' || at === arg.length - 1) {
          expanded.push('-' + short)
        } else {
          expanded.push('-' + arg.slice(at))
          break
        }
      }
      remaining.unshift(...expanded)
      groupCount = expanded.length
      continue
    }
    if (parseArgsIsShortValue(arg, options)) {
      tokens.push(parseArgsToken(parseArgsLongFor(options, arg[1]), '-' + arg[1], index, arg.slice(2), true))
      continue
    }
    if (arg.length > 2 && arg.startsWith('--') && !arg.includes('=')) {
      let name = arg.slice(2)
      if (allowNegative && !parseArgsOptionOf(options, name) && name.startsWith('no-') && parseArgsOptionOf(options, name.slice(3))?.type === 'boolean') name = name.slice(3)
      let value
      let inlineValue
      if (parseArgsOptionOf(options, name)?.type === 'string' && next !== undefined) {
        value = remaining.shift()
        inlineValue = false
      }
      tokens.push(parseArgsToken(name, arg, index, value, inlineValue))
      if (value !== undefined) index += 1
      continue
    }
    if (arg.length > 2 && arg.startsWith('--')) {
      const equal = arg.indexOf('=')
      const name = arg.slice(2, equal)
      tokens.push(parseArgsToken(name, '--' + name, index, arg.slice(equal + 1), true))
      continue
    }
    tokens.push({ kind: 'positional', index, value: arg })
  }
  return tokens
}

const parseArgs = (config = {}) => {
  const args = config.args ?? []
  const options = config.options ?? {}
  const strict = config.strict ?? true
  const allowPositionals = config.allowPositionals ?? !strict
  const allowNegative = config.allowNegative ?? false
  const tokens = parseArgsTokenize(args, options, allowNegative)
  const values = {}
  const positionals = []
  for (const token of tokens) {
    if (token.kind === 'option') {
      const negated = token.rawName.startsWith('--no-') && token.name === token.rawName.slice(5)
      const option = parseArgsOptionOf(options, token.name)
      if (strict) {
        const hint = allowPositionals ? ". To specify a positional argument starting with a '-', place it at the end of the command after '--', as in '-- " + JSON.stringify(token.rawName) : ''
        if (!option) throw parseArgsError('ERR_PARSE_ARGS_UNKNOWN_OPTION', "Unknown option '" + token.rawName + "'" + hint)
        const label = (option.short ? '-' + option.short + ', ' : '') + '--' + token.name
        if (option.type === 'string' && token.value === undefined) throw parseArgsError('ERR_PARSE_ARGS_INVALID_OPTION_VALUE', "Option '" + label + " <value>' argument missing")
        if (option.type === 'string' && !token.inlineValue && token.value.length > 1 && token.value[0] === '-') {
          const shortForm = token.rawName.length === 2 ? " or '-" + token.name[0] + "-XYZ'" : ''
          throw parseArgsError('ERR_PARSE_ARGS_INVALID_OPTION_VALUE', "Option '" + token.rawName + "' argument is ambiguous.\nDid you forget to specify the option argument for '" + token.rawName + "'?\nTo specify an option argument starting with a dash use '--" + token.name + "=-XYZ'" + shortForm + '.')
        }
        if (option.type === 'boolean' && token.value !== undefined) throw parseArgsError('ERR_PARSE_ARGS_INVALID_OPTION_VALUE', "Option '" + label + "' does not take an argument")
      }
      if (token.name === '__proto__') continue
      let value = token.value
      if (negated) value = false
      else if (value === undefined) value = true
      if (option?.multiple) values[token.name] = [...(values[token.name] ?? []), value]
      else values[token.name] = value
    } else if (token.kind === 'positional') {
      if (!allowPositionals) throw parseArgsError('ERR_PARSE_ARGS_UNEXPECTED_POSITIONAL', "Unexpected argument '" + token.value + "'. This command does not take positional arguments")
      positionals.push(token.value)
    }
  }
  for (const name of Object.keys(options)) {
    if (options[name].default !== undefined && values[name] === undefined) values[name] = options[name].default
  }
  const result = { values, positionals }
  if (config.tokens) result.tokens = tokens
  return result
}

const stripVTControlCharacters = (text) => String(text).replace(/[\u001b\u009b][[()#;?]*(?:[0-9]{1,4}(?:;[0-9]{0,4})*)?[0-9A-ORZcf-nqry=><]/g, '')

const util = { TextDecoder, inspect, isDeepStrictEqual, parseArgs, parseEnv, promisify, stripVTControlCharacters }

const utilTypes = { isPromise: (value) => value instanceof Promise }

const requireCache = new Map()
const resolveFrom = (dir, request) => {
  const stack = []
  for (const part of (request.startsWith('/') ? request : dir + '/' + request).split('/')) {
    if (part === '..') stack.pop()
    else if (part !== '' && part !== '.') stack.push(part)
  }
  return '/' + stack.join('/')
}
const loadModule = (path) => {
  if (requireCache.has(path)) return requireCache.get(path).exports
  const record = { exports: {} }
  requireCache.set(path, record)
  if (path.endsWith('.json')) {
    record.exports = JSON.parse(readText(path))
    return record.exports
  }
  new Function('module', 'exports', 'require', readText(path))(record, record.exports, createRequire(path))
  return record.exports
}
const createRequire = (filename) => {
  const text = String(filename.href ?? filename)
  const local = decodeURIComponent(text.startsWith('file://') ? text.slice(7) : text)
  const dir = local.slice(0, local.lastIndexOf('/'))
  return (request) => loadModule(resolveFrom(dir, String(request)))
}
const moduleApi = { createRequire, stripTypeScriptTypes: fail('module.stripTypeScriptTypes') }

const envRecord = (env) => Object.fromEntries(Object.entries(env).filter(([, value]) => value !== undefined).map(([key, value]) => [key, String(value)]))

const outputEncoding = (options, fallback) => (options.encoding === undefined ? fallback : options.encoding)

const decodeOutput = (bytes, encoding) => (encoding === null || encoding === 'buffer' ? wrapBytes(bytes) : fromBytes(bytes, encoding))

const runCommand = (file, argv, options) => {
  const reply = host('run_command', {
    file: String(file),
    args: argv.map(String),
    cwd: options.cwd ?? null,
    env: options.env === undefined ? undefined : envRecord(options.env),
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

const commandLine = (file, argv) => [file, ...argv].join(' ')

const shellInvocation = (file, argv, options) => (options.shell ? [typeof options.shell === 'string' ? options.shell : '/bin/sh', ['-c', commandLine(file, argv)]] : [file, argv])

const commandFailure = (file, argv, result, options) => {
  const stdout = decodeOutput(result.stdout, outputEncoding(options, 'utf8'))
  const stderr = decodeOutput(result.stderr, outputEncoding(options, 'utf8'))
  const cmd = commandLine(file, argv)
  const error = new Error('Command failed: ' + cmd + '\n' + String(stderr))
  error.code = result.status ?? null
  error.killed = false
  error.signal = signalNameOf(result.signal)
  error.cmd = cmd
  error.stdout = stdout
  error.stderr = stderr
  return error
}

const spawnFailure = (file, argv, code) => {
  const error = new Error('spawn ' + String(file) + ' ' + code)
  error.errno = code === 'ENOENT' ? -2 : undefined
  error.code = code
  error.signal = null
  error.cmd = commandLine(file, argv)
  error.syscall = code === 'ENOTDIR' ? 'spawn' : 'spawn ' + String(file)
  error.path = String(file)
  error.spawnargs = argv.map(String)
  error.stdout = ''
  error.stderr = ''
  return error
}

const execFileSync = (file, args, options) => {
  const { argv, options: resolved } = normalizeExecArgs(args, options)
  const result = runCommand(file, argv, resolved)
  if (result.status !== 0) throw commandFailure(file, argv, result, resolved)
  return decodeOutput(result.stdout, outputEncoding(resolved, 'buffer'))
}

const spawnSync = (file, args, options) => {
  const { argv, options: resolved } = normalizeExecArgs(args, options)
  const result = runCommand(file, argv, resolved)
  const stdout = decodeOutput(result.stdout, outputEncoding(resolved, 'buffer'))
  const stderr = decodeOutput(result.stderr, outputEncoding(resolved, 'buffer'))
  return { pid: 0, output: [null, stdout, stderr], stdout, stderr, status: result.status, signal: result.signal, error: undefined }
}

const executionFailure = (cmd, code, signal, killed, stdout, stderr) => {
  const error = new Error('Command failed: ' + cmd + '\n' + String(stderr))
  error.code = code ?? null
  error.killed = killed
  error.signal = signal
  error.cmd = cmd
  error.stdout = stdout
  error.stderr = stderr
  return error
}

const execFile = (file, ...rest) => {
  const callback = typeof rest[rest.length - 1] === 'function' ? rest.pop() : undefined
  const { argv, options } = normalizeExecArgs(rest[0], rest[1])
  const child = spawnStreams(file, argv, { ...options, stdio: 'pipe', windowsHide: options.windowsHide === undefined ? undefined : Boolean(options.windowsHide) })
  const encoding = outputEncoding(options, 'utf8')
  const limit = options.maxBuffer === undefined ? 1024 * 1024 : Number(options.maxBuffer)
  const out = []
  const err = []
  const seen = { stdout: 0, stderr: 0 }
  let overflow = null
  const collect = (name, list) => (chunk) => {
    const bytes = toBytes(chunk)
    seen[name] += bytes.length
    list.push(bytes)
    if (seen[name] > limit && overflow === null) {
      overflow = name
      child.kill('SIGTERM')
    }
  }
  child.stdout.on('data', collect('stdout', out))
  child.stderr.on('data', collect('stderr', err))
  let finished = false
  const finish = (failure, stdout, stderr) => {
    if (finished) return
    finished = true
    if (typeof callback === 'function') callback(failure ?? null, stdout, stderr)
  }
  child.on('error', (error) => finish(error, decodeOutput(new Uint8Array(0), encoding), decodeOutput(new Uint8Array(0), encoding)))
  child.on('close', (code, signal) => {
    const stdout = decodeOutput(concatBytes(out).subarray(0, limit), encoding)
    const stderr = decodeOutput(concatBytes(err).subarray(0, limit), encoding)
    if (overflow !== null) {
      const error = new RangeError(overflow + ' maxBuffer length exceeded')
      error.code = 'ERR_CHILD_PROCESS_STDIO_MAXBUFFER'
      error.killed = null
      error.signal = null
      finish(error, stdout, stderr)
      return
    }
    const failed = code !== 0 || signal !== null
    finish(failed ? executionFailure(commandLine(file, argv), code, signal, child.killed, stdout, stderr) : null, stdout, stderr)
  })
  return child
}

const signalNames = { 1: 'SIGHUP', 2: 'SIGINT', 3: 'SIGQUIT', 6: 'SIGABRT', 9: 'SIGKILL', 10: 'SIGUSR1', 12: 'SIGUSR2', 13: 'SIGPIPE', 14: 'SIGALRM', 15: 'SIGTERM' }
const signalNumbers = Object.fromEntries(Object.entries(signalNames).map(([number, name]) => [name, Number(number)]))
const signalNameOf = (number) => (number === null || number === undefined ? null : signalNames[number] ?? 'SIG' + number)
const streamClosed = (stream) => new Promise((resolve) => {
  if (stream.destroyed) resolve()
  else stream.on('close', resolve)
})

class ChildProcess extends FxEmitter {
  constructor(file, args, options = {}) {
    super()
    this.timeoutMs = Number(options.timeout ?? 0)
    this.killSignal = options.killSignal ?? 'SIGTERM'
    this.spawnfile = String(file)
    this.spawnargs = [String(file), ...args.map(String)]
    this.pid = undefined
    this.exitCode = null
    this.signalCode = null
    this.killed = false
    this.procId = undefined
    this.stdin = new Writable({
      write: (chunk, encoding, callback) => {
        if (this.procId !== undefined) host('proc_write', { id: this.procId, body: encodeBase64(typeof chunk === 'string' ? encodeUtf8(chunk) : toBytes(chunk)) })
        callback()
      },
    })
    const closeStdin = () => {
      if (this.procId !== undefined && this.stdinClosed !== true) {
        this.stdinClosed = true
        host('proc_close_stdin', { id: this.procId })
      }
    }
    this.stdin.on('finish', closeStdin)
    this.stdin.on('close', closeStdin)
    this.stdout = new Readable()
    this.stdout._read = () => {}
    this.stderr = new Readable()
    this.stderr._read = () => {}
  }
  kill(signal = 'SIGTERM') {
    if (typeof signal === 'string' && signalNumbers[signal] === undefined) throw typeErrorCoded('ERR_UNKNOWN_SIGNAL', 'Unknown signal: ' + signal)
    if (this.procId === undefined || this.exitCode !== null || this.signalCode !== null) return false
    const reply = host('proc_kill', { id: this.procId, signal: typeof signal === 'number' ? signal : signalNumbers[signal] })
    if (reply.delivered) this.killed = true
    return reply.delivered === true
  }
  async pump(stream, which, deadline) {
    for (;;) {
      const reply = host('proc_read', { id: this.procId, stream: which, wait_ms: 5 })
      if (reply.pending) {
        if (deadline !== null && !this.killed && Date.now() >= deadline) this.kill(this.killSignal)
        await new Promise((resolve) => setTimeout(resolve, 0))
        continue
      }
      if (reply.eof) break
      const bytes = decodeBase64(reply.body)
      stream.push(stream.encoding ? fromBytes(bytes, stream.encoding) : wrapBytes(bytes))
    }
    stream.push(null)
  }
  async run() {
    const deadline = this.timeoutMs > 0 ? Date.now() + this.timeoutMs : null
    const pumps = []
    if (this.stdout !== null) pumps.push(this.pump(this.stdout, 'stdout', deadline))
    if (this.stderr !== null) pumps.push(this.pump(this.stderr, 'stderr', deadline))
    await Promise.all(pumps)
    const reply = host('proc_wait', { id: this.procId })
    this.exitCode = reply.code ?? null
    this.signalCode = signalNameOf(reply.signal)
    this.emit('exit', this.exitCode, this.signalCode)
    if (this.abortError !== undefined) this.emit('error', this.abortError)
    const streams = [this.stdout, this.stderr].filter((stream) => stream !== null)
    for (const stream of streams) {
      if (!stream.flowing) stream.resume()
    }
    await Promise.all(streams.map(streamClosed))
    this.emit('close', this.exitCode, this.signalCode)
  }
}

const stdioMode = (mode) => (mode === undefined || mode === 'overlapped' ? 'pipe' : mode)

const checkChildOptions = (options) => {
  if (typeof options.stdio === 'string' && !['pipe', 'ignore', 'inherit', 'overlapped'].includes(options.stdio)) {
    throw typeErrorCoded('ERR_INVALID_ARG_VALUE', "The argument 'stdio' is invalid. Received '" + options.stdio + "'")
  }
  if (options.shell !== undefined && typeof options.shell !== 'boolean' && typeof options.shell !== 'string') {
    throw typeErrorCoded('ERR_INVALID_ARG_TYPE', 'The "options.shell" property must be one of type boolean or string. Received ' + receivedText(options.shell))
  }
  if (options.signal !== undefined && options.signal !== null && typeof options.signal !== 'object') {
    throw typeErrorCoded('ERR_INVALID_ARG_TYPE', 'The "options.signal" property must be an instance of AbortSignal. Received ' + receivedText(options.signal))
  }
  for (const key of ['uid', 'gid']) {
    const id = options[key]
    if (id !== undefined && !(Number.isInteger(id) && id >= -2147483648 && id <= 2147483647)) {
      throw typeErrorCoded('ERR_INVALID_ARG_TYPE', 'The "options.' + key + '" property must be int32. Received ' + receivedText(id))
    }
  }
  if (options.windowsHide !== undefined && typeof options.windowsHide !== 'boolean') {
    throw typeErrorCoded('ERR_INVALID_ARG_TYPE', 'The "options.windowsHide" property must be of type boolean. Received ' + receivedText(options.windowsHide))
  }
  if (options.maxBuffer !== undefined && !(typeof options.maxBuffer === 'number' && options.maxBuffer >= 0)) {
    throw rangeErrorCoded('ERR_OUT_OF_RANGE', 'The value of "options.maxBuffer" is out of range. It must be a positive number. Received ' + (typeof options.maxBuffer === 'string' ? "'" + options.maxBuffer + "'" : String(options.maxBuffer)))
  }
  if (options.timeout !== undefined && (!Number.isInteger(options.timeout) || options.timeout < 0)) {
    throw rangeErrorCoded('ERR_OUT_OF_RANGE', 'The value of "timeout" is out of range. It must be an unsigned integer. Received ' + (typeof options.timeout === 'string' ? "'" + options.timeout + "'" : String(options.timeout)))
  }
  const signal = options.killSignal
  const known = typeof signal === 'number' ? Object.values(signalNumbers).includes(signal) : signalNumbers[signal] !== undefined
  if (signal !== undefined && !known) throw typeErrorCoded('ERR_UNKNOWN_SIGNAL', 'Unknown signal: ' + String(signal))
}
const spawnStreams = (file, args = [], options = {}) => {
  checkChildOptions(options)
  const [shellCommand, shellArgs] = shellInvocation(file, args.map(String), options)
  const [command, commandArgs] = options.detached === true ? ['setsid', [shellCommand, ...shellArgs]] : [shellCommand, shellArgs]
  const request = { file: String(command), args: commandArgs.map(String) }
  const stdioModes = Array.isArray(options.stdio) ? options.stdio : [options.stdio ?? 'pipe', options.stdio ?? 'pipe', options.stdio ?? 'pipe']
  request.stdin_mode = stdioMode(stdioModes[0])
  request.stdout_mode = stdioMode(stdioModes[1])
  request.stderr_mode = stdioMode(stdioModes[2])
  if (options.cwd !== undefined) request.cwd = String(options.cwd)
  if (options.env !== undefined) request.env_json = JSON.stringify(envRecord(options.env))
  const reply = globalThis.gm.proc_spawn(request)
  const child = new ChildProcess(file, args, options)
  if (reply.ok === false) {
    if (reply.error === 'NotDir') throw Object.assign(spawnFailure(file, args, 'ENOTDIR'), { message: 'spawn ENOTDIR' })
    const error = spawnFailure(file, args, 'ENOENT')
    nextTick(() => {
      child.emit('error', error)
      child.emit('close', -2, null)
    })
    return child
  }
  child.pid = reply.pid
  child.procId = reply.id
  if (options.signal !== undefined && options.signal !== null) {
    const onAbort = () => {
      child.abortError = abortedError()
      child.kill('SIGTERM')
    }
    if (options.signal.aborted) onAbort()
    else options.signal.addEventListener('abort', onAbort, { once: true })
  }
  if (request.stdin_mode !== 'pipe') child.stdin = null
  if (request.stdout_mode !== 'pipe') child.stdout = null
  if (request.stderr_mode !== 'pipe') child.stderr = null
  child.stdio = [child.stdin, child.stdout, child.stderr]
  nextTick(() => {
    child.emit('spawn')
    child.run().catch((error) => child.emit('error', error))
  })
  return child
}
const exec = (command, ...rest) => {
  const callback = typeof rest[rest.length - 1] === 'function' ? rest.pop() : undefined
  const options = typeof rest[0] === 'object' && rest[0] !== null ? rest[0] : {}
  const shellOptions = { ...options, shell: true }
  return callback === undefined ? execFile(String(command), [], shellOptions) : execFile(String(command), [], shellOptions, callback)
}
const childProcess = { exec, execFile, execFileSync, spawn: spawnStreams, spawnSync }

const networkInterfaces = () => {
  const out = {}
  for (const { name, ...details } of host('net_interfaces', {}).interfaces) (out[name] ??= []).push(details)
  return out
}

const os = {
  availableParallelism: () => processInfo().parallelism,
  constants: { signals: {}, errno: {} },
  homedir: () => processInfo().homedir,
  networkInterfaces,
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

const scopeKeysHidden = new Set(['__fxScope', '__fxSource', 'eval'])

const scopeFor = (sandbox) => new Proxy(sandbox, {
  has: (target, key) => typeof key === 'string' && !scopeKeysHidden.has(key),
  get: (target, key) => (key in target ? target[key] : globalThis[key]),
  set: (target, key, value) => {
    target[key] = value
    return true
  },
})

const runInContext = (code, sandbox) => {
  const run = new Function('__fxScope', '__fxSource', 'with (__fxScope) { return eval(__fxSource) }')
  return run(scopeFor(sandbox), String(code))
}

const createContext = (sandbox = {}) => sandbox

class Script {
  constructor(code) {
    this.code = String(code)
    new Function(this.code)
  }
  runInThisContext() {
    return (0, eval)(this.code)
  }
  runInContext(sandbox) {
    return runInContext(this.code, sandbox)
  }
  runInNewContext(sandbox = {}) {
    return runInContext(this.code, createContext(sandbox))
  }
}

const runInNewContext = (code, sandbox = {}) => runInContext(code, createContext(sandbox))

const vm = { Script, createContext, runInContext, runInNewContext }

const validateHeaderValue = (name, value) => {
  if (value === undefined) {
    const error = new TypeError('Invalid value "undefined" for header "' + String(name) + '"')
    error.code = 'ERR_HTTP_INVALID_HEADER_VALUE'
    throw error
  }
  if (/[^\t\x20-\x7e\x80-\xff]/.test(String(value))) {
    const error = new TypeError('Invalid character in header content ["' + String(name) + '"]')
    error.code = 'ERR_INVALID_CHAR'
    throw error
  }
}

const createServer = (handler = () => {}) => {
  const server = {
    closed: false,
    id: 0,
    port: 0,
    listen: (port = 0, bind = '127.0.0.1', callback) => {
      if (typeof bind === 'function') {
        callback = bind
        bind = '127.0.0.1'
      }
      const reply = host('serve_listen', { url: 'http://' + bind + '/', loopback: true, host: bind, port })
      server.id = reply.id
      server.port = reply.port
      if (callback) callback()
      while (!server.closed) {
        const request = host('serve_accept', { id: server.id })
        const res = {
          statusCode: 200,
          setHeader: () => {},
          writeHead: (code) => { res.statusCode = code },
          end: (body = '') => host('serve_respond', { conn: request.conn, status: res.statusCode, body: String(body) }),
        }
        handler({ method: request.method, url: request.path, body: request.body }, res)
      }
      return server
    },
    close: () => { server.closed = true },
    address: () => ({ port: server.port, address: '127.0.0.1' }),
  }
  return server
}

const http = { createServer, validateHeaderValue }

const httpsRequest = (url, options = {}, callback) => {
  if (typeof options === 'function') {
    callback = options
    options = {}
  }
  const reply = host('net_fetch', { url: String(url), method: 'GET', loopback: options.allowLoopback === true })
  const body = fromBytes(decodeBase64(reply.body), 'utf8')
  const response = {
    statusCode: reply.status,
    on: (event, listener) => {
      if (event === 'data') listener(body)
      if (event === 'end') listener()
      return response
    },
  }
  if (callback) callback(response)
  return response
}

const https = { createServer: fail('https.createServer'), get: httpsRequest, request: httpsRequest }

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
      if (pos >= input.length) throw zlibError('Z_BUF_ERROR', 'unexpected end of file')
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

const skipZeroTerminated = (input, from) => {
  let at = from
  while (at < input.length && input[at] !== 0) at += 1
  if (at >= input.length) throw zlibError('Z_BUF_ERROR', 'unexpected end of file')
  return at + 1
}

const zlibError = (code, message) => {
  const error = new Error(message)
  error.code = code
  return error
}

const gunzipMember = (input, start) => {
  if (input[start] !== 0x1f || input[start + 1] !== 0x8b) throw zlibError('Z_DATA_ERROR', 'incorrect header check')
  if (input.length - start < 10) throw zlibError('Z_BUF_ERROR', 'unexpected end of file')
  const flags = input[start + 3]
  let pos = start + 10
  if (flags & 4) pos += 2 + (input[pos] | (input[pos + 1] << 8))
  if (flags & 8) pos = skipZeroTerminated(input, pos)
  if (flags & 16) pos = skipZeroTerminated(input, pos)
  if (flags & 2) pos += 2
  const result = inflateRaw(input.subarray(pos))
  const trailer = pos + result.consumed
  if (trailer + 8 > input.length) throw zlibError('Z_BUF_ERROR', 'unexpected end of file')
  const crc = (input[trailer] | (input[trailer + 1] << 8) | (input[trailer + 2] << 16) | (input[trailer + 3] << 24)) >>> 0
  const size = (input[trailer + 4] | (input[trailer + 5] << 8) | (input[trailer + 6] << 16) | (input[trailer + 7] << 24)) >>> 0
  if (crc !== crc32(result.data)) throw zlibError('Z_DATA_ERROR', 'incorrect data check')
  if (size !== result.data.length >>> 0) throw zlibError('Z_DATA_ERROR', 'incorrect length check')
  return { data: result.data, end: trailer + 8 }
}

const gunzipBytes = (input) => {
  if (input.length === 0) throw zlibError('Z_BUF_ERROR', 'unexpected end of file')
  const parts = []
  let pos = 0
  while (pos < input.length) {
    const member = gunzipMember(input, pos)
    parts.push(member.data)
    pos = member.end
  }
  return concatBytes(parts)
}

const deflateBytes = (bytes) => concatBytes([new Uint8Array([0x78, 0x01]), storedDeflate(bytes), u32be(adler32(bytes))])

const inflateBytes = (input) => {
  if ((input[0] & 0x0f) !== 8 || ((input[0] << 8) | input[1]) % 31 !== 0) throw zlibError('Z_DATA_ERROR', 'incorrect header check')
  const result = inflateRaw(input.subarray(2))
  const trailer = 2 + result.consumed
  const expected = ((input[trailer] << 24) | (input[trailer + 1] << 16) | (input[trailer + 2] << 8) | input[trailer + 3]) >>> 0
  if (expected !== adler32(result.data)) throw new Error('zlib: Adler-32 mismatch')
  return result.data
}

const asInput = (data) => {
  if (typeof data === 'string') return encodeUtf8(data)
  if (data instanceof ArrayBuffer) return new Uint8Array(data)
  if (ArrayBuffer.isView(data)) return new Uint8Array(data.buffer, data.byteOffset, data.byteLength)
  throw typeErrorCoded('ERR_INVALID_ARG_TYPE', 'The "chunk" argument must be of type string or an instance of Buffer, TypedArray, or DataView. Received ' + receivedText(data))
}

const zlibAsync = (transform) => (data, ...rest) => {
  const callback = rest[rest.length - 1]
  const input = asInput(data)
  queueMicrotask(() => {
    let output
    try {
      output = wrapBytes(transform(input))
    } catch (error) {
      callback(error)
      return
    }
    callback(null, output)
  })
}

class ZlibStream extends PassThrough {
  constructor(transform) {
    super()
    this.transform = transform
    this.chunks = []
  }
  write(chunk) {
    this.chunks.push(asInput(chunk))
    return true
  }
  end(chunk) {
    if (chunk !== undefined && chunk !== null) this.write(chunk)
    const total = this.chunks.reduce((length, part) => length + part.length, 0)
    const joined = new Uint8Array(total)
    let offset = 0
    for (const part of this.chunks) {
      joined.set(part, offset)
      offset += part.length
    }
    try {
      this.push(wrapBytes(this.transform(joined)))
    } catch (error) {
      this.emit('error', error)
      return this
    }
    this.push(null)
    return this
  }
}

const zlib = {
  createGzip: () => new ZlibStream(gzipBytes),
  createGunzip: () => new ZlibStream(gunzipBytes),
  createDeflate: () => new ZlibStream(deflateBytes),
  createInflate: () => new ZlibStream(inflateBytes),
  gzipSync: (data) => wrapBytes(gzipBytes(asInput(data))),
  gunzipSync: (data) => wrapBytes(gunzipBytes(asInput(data))),
  deflateSync: (data) => wrapBytes(deflateBytes(asInput(data))),
  inflateSync: (data) => wrapBytes(inflateBytes(asInput(data))),
  gzip: zlibAsync(gzipBytes),
  gunzip: zlibAsync(gunzipBytes),
  deflate: zlibAsync(deflateBytes),
  inflate: zlibAsync(inflateBytes),
  brotliCompress: fail('zlib.brotliCompress'),
  constants: {},
  createZstdDecompress: fail('zlib.createZstdDecompress'),
  zstdCompress: fail('zlib.zstdCompress'),
  zstdDecompress: fail('zlib.zstdDecompress'),
  zstdDecompressSync: fail('zlib.zstdDecompressSync'),
}

class InspectorSession {
  connect() {}
  disconnect() {}
  post(method, params, callback) {
    const done = typeof params === 'function' ? params : callback
    const input = typeof params === 'function' ? {} : (params ?? {})
    let result = {}
    if (method === 'Runtime.evaluate') {
      const value = runInContext(input.expression, {})
      result = { result: { type: typeof value, value } }
    }
    if (done) done(null, result)
    return result
  }
}

const inspector = { Session: InspectorSession }

const stringDecoderEncodings = {
  utf8: 'utf8',
  'utf-8': 'utf8',
  ucs2: 'ucs2',
  'ucs-2': 'ucs2',
  utf16le: 'ucs2',
  'utf-16le': 'ucs2',
  latin1: 'latin1',
  binary: 'latin1',
  base64: 'base64',
  base64url: 'base64url',
  hex: 'hex',
  ascii: 'ascii',
}

class StringDecoder {
  constructor(encoding = 'utf8') {
    const name = stringDecoderEncodings[String(encoding).toLowerCase()]
    if (name === undefined) throw new TypeError('Unknown encoding: ' + encoding)
    this.encoding = name
    this.pending = new Uint8Array(0)
  }
  write(chunk) {
    let bytes = concatBytes([this.pending, toBytes(chunk)])
    let head = ''
    if (this.encoding === 'ucs2' && this.pending.length === 1 && bytes.length >= 2) {
      head = fromBytes(bytes.subarray(0, 2), 'ucs2')
      bytes = bytes.subarray(2)
    }
    const keep = this.trailingBytes(bytes)
    this.pending = bytes.slice(bytes.length - keep)
    const complete = bytes.subarray(0, bytes.length - keep)
    return head + (this.encoding === 'utf8' ? decodeUtf8(complete) : fromBytes(complete, this.encoding))
  }
  trailingBytes(bytes) {
    if (this.encoding === 'utf8') return incompleteTail(bytes)
    if (this.encoding === 'base64' || this.encoding === 'base64url') return bytes.length % 3
    if (this.encoding === 'ucs2') {
      const odd = bytes.length % 2
      const last = bytes.length - odd - 2
      const unit = last >= 0 ? bytes[last] | (bytes[last + 1] << 8) : 0
      return odd + (unit >= 0xd800 && unit <= 0xdbff ? 2 : 0)
    }
    return 0
  }
  end(chunk) {
    const text = chunk === undefined ? '' : this.write(chunk)
    const rest = this.pending
    this.pending = new Uint8Array(0)
    if (rest.length === 0) return text
    return text + (this.encoding === 'utf8' ? decodeUtf8(rest) : fromBytes(rest, this.encoding))
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

const abortError = (signal) => {
  const error = new Error('The operation was aborted')
  error.name = 'AbortError'
  error.code = 'ABORT_ERR'
  error.cause = signal.reason
  return error
}

const timersPromises = {
  scheduler: {
    wait: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
    yield: () => new Promise((resolve) => setTimeout(resolve, 0)),
  },
  setTimeout: (ms, value, options = {}) => new Promise((resolve, reject) => {
    const signal = options.signal
    if (signal?.aborted) {
      reject(abortError(signal))
      return
    }
    const onAbort = () => {
      clearTimeout(timer)
      reject(abortError(signal))
    }
    const timer = setTimeout(() => {
      signal?.removeEventListener('abort', onAbort)
      resolve(value)
    }, ms)
    signal?.addEventListener('abort', onAbort, { once: true })
  }),
}

const net = {
  isIP: (text) => {
    if (/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.test(text)) return 4
    if (text.includes(':') && /^[0-9a-fA-F:.]+$/.test(text)) return 6
    return 0
  },
}

const dnsNotFound = (hostname) => {
  const error = new Error('getaddrinfo ENOTFOUND ' + String(hostname))
  error.code = 'ENOTFOUND'
  error.syscall = 'getaddrinfo'
  error.hostname = String(hostname)
  return error
}

const dnsEntries = (hostname) => {
  const name = String(hostname)
  if (/^\d{1,3}(\.\d{1,3}){3}$/.test(name)) return [{ address: name, family: 4 }]
  if (name.includes(':')) return [{ address: name, family: 6 }]
  if (name === 'localhost') return [{ address: '127.0.0.1', family: 4 }, { address: '::1', family: 6 }]
  try {
    const reply = host('dns_lookup', { url: 'https://' + name + '/' })
    return [{ address: reply.address, family: reply.family }]
  } catch (error) {
    throw dnsNotFound(name)
  }
}

const dnsPromises = {
  lookup: async (hostname, options) => {
    const settings = typeof options === 'object' && options !== null ? options : {}
    const family = typeof options === 'number' ? options : settings.family ?? 0
    const entries = dnsEntries(hostname).filter((entry) => Number(family) === 0 || entry.family === Number(family))
    if (entries.length === 0) throw dnsNotFound(hostname)
    return settings.all === true ? entries : entries[0]
  },
  resolve: fail('dns.resolve'),
}

const processObject = {
  get env() { return processInfo().env },
  get argv() { return processInfo().argv },
  get execPath() { return processInfo().execPath },
  get pid() { return processInfo().pid },
  get platform() { return processInfo().platform },
  get version() { return processInfo().version },
  exitCode: undefined,
  cwd: () => processInfo().cwd,
  exit: (code = 0) => globalThis.__fxExitNow(code),
  kill: (pid, signal = 'SIGTERM') => {
    const name = String(signal).replace(/^SIG/, '')
    const result = childProcess.spawnSync('kill', ['-s', name, String(pid)])
    if (result.status !== 0) throw Object.assign(nodeError('ESRCH', 'kill ESRCH'), { errno: -3, syscall: 'kill' })
    return true
  },
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

const agentState = { dir: '.fx/agents' }

const agentFile = (key) => agentState.dir + '/' + String(key) + '.json'

const agentPersistence = {
  write: (key, value) => {
    host('fs_mkdir', { path: agentState.dir, recursive: true })
    host('fs_write', { path: agentFile(key), base64: encodeBase64(toBytes(JSON.stringify(value), 'utf8')), append: false })
  },
  read: (key) => {
    try {
      return JSON.parse(fromBytes(decodeBase64(host('fs_read', { path: agentFile(key) }).base64), 'utf8'))
    } catch (error) {
      return undefined
    }
  },
}

const agentCore = {
  name: 'fx',
  interface: 1,
  turn: (prompt) => {
    const id = host('proc_spawn', { file: 'fx', args: ['ask', String(prompt)] }).id
    let text = ''
    for (;;) {
      const reply = host('proc_read', { id, stream: 'stdout' })
      if (reply.eof) break
      text += fromBytes(decodeBase64(reply.body), 'utf8')
    }
    host('proc_wait', { id })
    return text.trim()
  },
}

const askFlags = (options, session) => {
  const args = ['ask', '--output-format', 'stream-json']
  const value = (flag, item) => { if (item !== undefined && item !== null) args.push(flag, String(item)) }
  value('--model', options.model)
  value('--provider', options.provider)
  value('--effort', options.effort)
  value('--system', options.system)
  value('--append-system-prompt', options.appendSystem)
  value('--permission-mode', options.permissionMode)
  value('--max-turns', options.maxTurns)
  value('--timeout', options.timeout)
  if (Array.isArray(options.tools)) args.push('--tools', options.tools.join(','))
  if (Array.isArray(options.allowedTools) && options.allowedTools.length > 0) args.push('--allowed-tools', options.allowedTools.join(','))
  if (Array.isArray(options.disallowedTools) && options.disallowedTools.length > 0) args.push('--disallowed-tools', options.disallowedTools.join(','))
  if (options.bare === true) args.push('--bare')
  if (options.save === false) args.push('--no-save')
  if (session) args.push('--resume', session)
  return args
}

const agentEventKind = (event) => {
  if (event.type === 'error') return 'error'
  if (event.role === 'meta') return event.type
  return event.role
}

const providerRequest = (provider, payload) => {
  const headers = { 'content-type': 'application/json' }
  if (provider.apiKey) headers.authorization = 'Bearer ' + provider.apiKey
  Object.assign(headers, provider.headers ?? {})
  const reply = host('net_fetch', {
    url: String(provider.baseUrl).replace(/\/+$/, '') + '/chat/completions',
    method: 'POST',
    body: encodeBase64(toBytes(JSON.stringify(payload), 'utf8')),
    headers_json: JSON.stringify(headers),
    loopback: provider.allowLoopback === true,
  })
  const text = fromBytes(decodeBase64(reply.body), 'utf8')
  if (reply.status < 200 || reply.status >= 300) throw new Error('provider answered ' + reply.status + ': ' + text.slice(0, 300))
  return JSON.parse(text)
}

const verbCatalog = () => globalThis.gm.verbs()

const toolDefinitions = (tools) => {
  const definitions = []
  const runners = new Map()
  for (const entry of tools) {
    if (typeof entry === 'string') {
      const verb = verbCatalog().find((candidate) => candidate.name === entry && candidate.kind === 'tool')
      if (verb === undefined) throw new Error('agent: no built-in tool named ' + entry)
      definitions.push({ type: 'function', function: { name: verb.name, description: verb.description, parameters: verb.input_schema } })
      runners.set(verb.name, (args) => globalThis.gm[verb.name](args))
    } else {
      definitions.push({ type: 'function', function: { name: entry.name, description: entry.description ?? '', parameters: entry.parameters ?? { type: 'object', properties: {} } } })
      runners.set(entry.name, (args, context) => entry.run(args, context))
    }
  }
  return { definitions, runners }
}

const resultText = (value) => (typeof value === 'string' ? value : value === undefined ? '' : JSON.stringify(value))

const systemMessages = (options, context) => {
  const parts = []
  if (options.system) parts.push(String(options.system))
  const extra = Array.isArray(context) ? context : context ? [context] : []
  for (const part of extra) parts.push(String(part))
  return parts.length === 0 ? [] : [{ role: 'system', content: parts.join('\n\n') }]
}

const runAgentLoop = (options, input) => {
  const provider = options.provider
  if (provider === undefined || !provider.baseUrl) throw new Error('agent: options.provider.baseUrl is required for an in-process turn')
  const hooks = options.hooks ?? {}
  const call = (fn, payload) => (typeof fn === 'function' ? fn(payload) : undefined)
  const { definitions, runners } = toolDefinitions(options.tools ?? [])
  const history = [...(input.messages ?? [])]
  const added = []
  const events = []
  const emit = (kind, event) => {
    events.push({ kind, event })
    call(options.onEvent, { kind, event })
  }
  let text = ''
  let usage = null
  let stop = 'completed'
  call(hooks.turnStart, { messages: history, context: input.context })
  const maxSteps = options.maxSteps ?? 16
  for (let step = 0; step < maxSteps; step += 1) {
    const payload = { model: provider.model ?? options.model, messages: [...systemMessages(options, input.context), ...history, ...added] }
    if (definitions.length > 0) payload.tools = definitions
    const response = providerRequest(provider, payload)
    const message = response.choices[0].message
    usage = response.usage ?? usage
    const assistant = { role: 'assistant', content: message.content ?? null }
    if (Array.isArray(message.tool_calls) && message.tool_calls.length > 0) assistant.tool_calls = message.tool_calls
    added.push(assistant)
    emit('assistant', assistant)
    if (typeof message.content === 'string' && message.content !== '') text = message.content
    if (assistant.tool_calls === undefined) break
    for (const toolCall of assistant.tool_calls) {
      const name = toolCall.function.name
      let args
      try {
        args = JSON.parse(toolCall.function.arguments || '{}')
      } catch (error) {
        args = {}
      }
      let output
      const verdict = call(hooks.beforeTool, { id: toolCall.id, name, arguments: args })
      if (verdict && verdict.deny !== undefined) {
        output = 'Denied: ' + String(verdict.deny === true ? 'a hook denied this call' : verdict.deny)
      } else if (verdict && verdict.result !== undefined) {
        output = resultText(verdict.result)
      } else {
        if (verdict && verdict.arguments !== undefined) args = verdict.arguments
        const runner = runners.get(name)
        if (runner === undefined) {
          output = 'Unknown tool: ' + name
        } else {
          try {
            output = resultText(runner(args, { id: toolCall.id }))
          } catch (error) {
            output = 'Error: ' + String(error && error.message ? error.message : error)
          }
        }
      }
      const after = call(hooks.afterTool, { id: toolCall.id, name, arguments: args, content: output })
      if (after && after.result !== undefined) output = resultText(after.result)
      const toolMessage = { role: 'tool', tool_call_id: toolCall.id, content: output }
      added.push(toolMessage)
      emit('tool', toolMessage)
    }
    if (step === maxSteps - 1) stop = 'max_steps'
  }
  const record = { text, messages: added, events, usage, stop }
  call(hooks.turnEnd, record)
  return record
}

const agent = (options = {}) => {
  const hooks = options.hooks ?? {}
  const state = { session: options.session ?? null, running: null }
  const call = (fn, payload) => (typeof fn === 'function' ? fn(payload) : undefined)
  const deliver = (event, record) => {
    record.events.push(event)
    if (event.role === 'assistant' && Array.isArray(event.tool_calls)) {
      for (const toolCall of event.tool_calls) call(hooks.beforeTool, { id: toolCall.id, name: toolCall.function.name, arguments: toolCall.function.arguments })
    }
    if (event.role === 'tool') call(hooks.afterTool, { id: event.tool_call_id, content: event.content })
    if (event.role === 'assistant' && typeof event.content === 'string' && event.content !== '') record.text = event.content
    if (event.role === 'meta' && event.type === 'session.resume_hint') state.session = event.session_id
    if (event.type === 'error') record.error = event
    call(options.onEvent, { kind: agentEventKind(event), event })
  }
  const inProcess = options.provider !== undefined
  const log = []
  const run = (input) => runAgentLoop(options, input)
  const turn = (text) => {
    const user = { role: 'user', content: String(text) }
    const record = run({ messages: [...log, user], context: options.context })
    log.push(user, ...record.messages)
    return record
  }
  const prompt = (text) => {
    if (inProcess) return turn(text)
    const record = { text: '', events: [], error: null, session: state.session, exitCode: null }
    call(hooks.turnStart, { prompt: String(text) })
    const id = host('proc_spawn', { file: 'fx', args: [...askFlags(options, state.session), '--', String(text)], ...(options.cwd ? { cwd: options.cwd } : {}) }).id
    state.running = id
    let pending = ''
    for (;;) {
      const reply = host('proc_read', { id, stream: 'stdout' })
      if (reply.eof) break
      pending += fromBytes(decodeBase64(reply.body), 'utf8')
      let cut = pending.indexOf('\n')
      while (cut >= 0) {
        const line = pending.slice(0, cut).trim()
        pending = pending.slice(cut + 1)
        if (line !== '') {
          let event = null
          try { event = JSON.parse(line) } catch (error) { event = null }
          if (event) deliver(event, record)
        }
        cut = pending.indexOf('\n')
      }
    }
    const tail = pending.trim()
    if (tail !== '') {
      let event = null
      try { event = JSON.parse(tail) } catch (error) { event = null }
      if (event) deliver(event, record)
    }
    const waited = host('proc_wait', { id })
    state.running = null
    record.exitCode = waited.code ?? waited.exit_code ?? null
    record.session = state.session
    call(hooks.turnEnd, record)
    return record
  }
  const cancel = () => {
    if (state.running !== null) host('proc_kill', { id: state.running })
  }
  return {
    prompt,
    run,
    cancel,
    get session() { return state.session },
  }
}

const agentModule = { core: agentCore, persistence: agentPersistence, agent }

const sqlText = (value) => "'" + String(value).replace(/'/g, "''") + "'"

const sessionPersistence = (options = {}) => {
  const path = String(options.path ?? '.fx/sessions.sqlite')
  const cut = path.lastIndexOf('/')
  if (cut > 0) host('fs_mkdir', { path: path.slice(0, cut), recursive: true })
  const id = host('sqlite_open', { path }).id
  const exec = (sql) => host('sqlite_exec', { id, sql })
  const all = (sql) => host('sqlite_all', { id, sql }).rows
  exec('PRAGMA journal_mode=WAL')
  exec('PRAGMA synchronous=FULL')
  exec('CREATE TABLE IF NOT EXISTS sessions(id TEXT PRIMARY KEY, header TEXT NOT NULL, revision INTEGER NOT NULL DEFAULT 0)')
  exec('CREATE TABLE IF NOT EXISTS events(id TEXT NOT NULL, seq INTEGER NOT NULL, time INTEGER NOT NULL, type TEXT NOT NULL, data TEXT NOT NULL, PRIMARY KEY(id, seq))')
  const headerOf = (key) => {
    const rows = all('SELECT header FROM sessions WHERE id = ' + sqlText(key))
    if (rows.length === 0) throw new Error('no such session: ' + key)
    return JSON.parse(rows[0][0])
  }
  const nextSeq = (key) => Number(all('SELECT COALESCE(MAX(seq) + 1, 0) AS next FROM events WHERE id = ' + sqlText(key))[0][0])
  const insertAll = (key, events) => {
    exec('BEGIN IMMEDIATE')
    try {
      for (const event of events) {
        exec('INSERT INTO events(id, seq, time, type, data) VALUES(' + sqlText(key) + ', ' + Number(event.seq) + ', ' + Number(event.time ?? 0) + ', ' + sqlText(event.type) + ', ' + sqlText(JSON.stringify(event.data ?? null)) + ')')
      }
      exec('UPDATE sessions SET revision = revision + 1 WHERE id = ' + sqlText(key))
      exec('COMMIT')
    } catch (error) {
      exec('ROLLBACK')
      throw error
    }
  }
  const dropTorn = (key, seq) => {
    exec('BEGIN IMMEDIATE')
    try {
      exec('DELETE FROM events WHERE id = ' + sqlText(key) + ' AND seq >= ' + Number(seq))
      exec('UPDATE sessions SET revision = revision + 1 WHERE id = ' + sqlText(key))
      exec('COMMIT')
    } catch (error) {
      exec('ROLLBACK')
      throw error
    }
  }
  const rowsOf = (key, from) => {
    const events = []
    for (const row of all('SELECT seq, time, type, data FROM events WHERE id = ' + sqlText(key) + ' AND seq >= ' + Number(from) + ' ORDER BY seq')) {
      let data
      try {
        data = JSON.parse(row[3])
      } catch (error) {
        dropTorn(key, Number(row[0]))
        break
      }
      events.push({ seq: Number(row[0]), time: Number(row[1]), type: row[2], data })
    }
    return events
  }
  const closeOpenTurn = (key, events) => {
    let open = null
    for (const event of events) {
      if (event.type === 'turn/start') open = event.data.turn
      else if (event.type === 'turn/end' && event.data.turn === open) open = null
    }
    if (open === null) return events
    const closer = { seq: events.length, time: events.length === 0 ? 0 : events[events.length - 1].time, type: 'turn/end', data: { turn: open, reason: { kind: 'interrupted' } } }
    insertAll(key, [closer])
    return [...events, closer]
  }
  return {
    create: (header) => {
      exec('INSERT OR IGNORE INTO sessions(id, header, revision) VALUES(' + sqlText(header.id) + ', ' + sqlText(JSON.stringify(header)) + ', 0)')
    },
    append: (key, events) => {
      headerOf(key)
      let expected = nextSeq(key)
      for (const event of events) {
        if (event.seq !== expected) throw new Error('append to ' + key + ' needs seq ' + expected + ', got ' + event.seq)
        expected += 1
      }
      if (events.length > 0) insertAll(key, events)
    },
    load: (key) => {
      const meta = headerOf(key)
      return { meta, events: closeOpenTurn(key, rowsOf(key, 0)) }
    },
    readFrom: (key, seq) => {
      const meta = headerOf(key)
      return { meta, events: rowsOf(key, seq) }
    },
    list: () => all('SELECT header FROM sessions WHERE id IN (SELECT DISTINCT id FROM events) ORDER BY id').map((row) => JSON.parse(row[0])),
    listSnapshots: () => all('SELECT header, revision FROM sessions WHERE id IN (SELECT DISTINCT id FROM events) ORDER BY id').map((row) => ({ header: JSON.parse(row[0]), revision: Number(row[1]) })),
    close: () => host('sqlite_close', { id }),
  }
}

const sessionModule = { sessionPersistence }

const loaderState = { lastGood: new Map(), hot: new Map(), rev: new Map(), reloads: 0, history: new Map() }

const historyFile = (target) => target.slice(0, target.lastIndexOf('/')) + '/.fx-history.json'
const readHistoryFile = (file) => (host('fs_exists', { path: file }).exists === true ? JSON.parse(readText(file)) : {})
const historyOf = (target) => {
  if (!loaderState.history.has(target)) loaderState.history.set(target, readHistoryFile(historyFile(target))[target] ?? [])
  return loaderState.history.get(target)
}
const saveHistory = (target) => {
  const file = historyFile(target)
  const all = readHistoryFile(file)
  all[target] = loaderState.history.get(target)
  host('fs_write', { path: file, base64: encodeBase64(toBytes(JSON.stringify(all), 'utf8')), append: false })
}

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
    const past = historyOf(target)
    past.push(revision)
    saveHistory(target)
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
  const past = historyOf(target)
  if (past.length < 2) throw new Error('nothing to roll back to for ' + target)
  past.pop()
  saveHistory(target)
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
  sessionModule,
  wsModule,
  loaderModule,
  fetch,
  fs,
  fsPromises,
  path,
  crypto,
  stream,
  eventsModule,
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
