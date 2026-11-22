(function (callHost, verbsText, sink, rootDir) {
  const show = (value) => (typeof value === 'string' ? value : typeof value === 'object' && value !== null ? JSON.stringify(value) : String(value));
  const write = (...args) => sink(args.map(show).join(' '));
  globalThis.console = { log: write, info: write, debug: write, warn: write, error: write };
  delete globalThis.alert;
  delete globalThis.confirm;
  delete globalThis.prompt;
  const catalog = JSON.parse(verbsText);
  const rawCall = (name, args) => JSON.parse(callHost(name, JSON.stringify(args ?? {})));
  const gm = {};
  for (const verb of catalog) {
    if (verb.kind === 'host') {
      gm[verb.name] = (args) => rawCall(verb.name, args);
    } else {
      gm[verb.name] = (args) => {
        const reply = rawCall(verb.name, args);
        if (reply.ok === false) throw new Error(reply.error ?? verb.name + ' failed');
        return reply.text;
      };
    }
  }
  const aliases = { run_shell: 'Bash', grep: 'grep_files', find: 'glob_files', fetch: 'FetchURL' };
  for (const [alias, name] of Object.entries(aliases)) if (gm[name]) gm[alias] = gm[name];
  gm.verbs = (args) => {
    if (args && args.names) return catalog.map((verb) => verb.name);
    if (args && args.name !== undefined) {
      const found = catalog.find((verb) => verb.name === args.name);
      if (found === undefined) throw new Error('unknown verb: ' + args.name);
      return found;
    }
    return catalog;
  };
  globalThis.gm = gm;
  let host = null;
  let hostFailure = null;
  import('fx:host').then((loaded) => { host = loaded.default; }, (error) => { hostFailure = error; });
  const loadedHost = () => {
    if (host === null) throw hostFailure ?? new Error('fx:host did not load');
    return host;
  };

  const normalize = (path) => {
    const absolute = path.startsWith('/');
    const parts = [];
    for (const part of path.split('/')) {
      if (part === '' || part === '.') continue;
      if (part === '..') parts.pop();
      else parts.push(part);
    }
    return (absolute ? '/' : '') + parts.join('/');
  };
  const dirOf = (path) => {
    const index = path.lastIndexOf('/');
    return index <= 0 ? '/' : path.slice(0, index);
  };
  const readText = (path) => {
    const reply = rawCall('fx.read_text', { path });
    return reply.ok ? reply.text : null;
  };
  const resolveFile = (base) => {
    const candidates = [base, base + '.js', base + '.cjs', base + '.json', base + '/index.js', base + '/index.cjs', base + '/index.json'];
    return candidates.find((candidate) => readText(candidate) !== null) ?? null;
  };
  const moduleCache = new Map();
  const locatedErrors = new WeakSet();
  const functionHeaderLines = 2;
  const sourceLine = (error) => {
    const frame = /(?:<input>|<anonymous>):(\d+)/.exec(String(error.stack ?? ''));
    const line = frame === null ? 0 : Number(frame[1]) - functionHeaderLines;
    return line > 0 ? ':' + line : '';
  };
  const locate = (thrown, path, hasLines) => {
    const error = thrown !== null && typeof thrown === 'object' ? thrown : new Error(String(thrown));
    if (locatedErrors.has(error)) return error;
    error.message = path + (hasLines ? sourceLine(error) : '') + ': ' + error.message;
    locatedErrors.add(error);
    return error;
  };
  const loadFile = (path) => {
    const cached = moduleCache.get(path);
    if (cached) return cached.exports;
    const text = readText(path);
    const module = { exports: {}, id: path, filename: path };
    moduleCache.set(path, module);
    const isJson = path.endsWith('.json');
    const dir = dirOf(path);
    try {
      if (isJson) module.exports = JSON.parse(text);
      else new Function('exports', 'require', 'module', '__filename', '__dirname', text).call(module.exports, module.exports, makeRequire(dir), module, path, dir);
    } catch (thrown) {
      moduleCache.delete(path);
      throw locate(thrown, path, !isJson);
    }
    return module.exports;
  };
  const makeRequire = (dir) => (spec) => {
    if (spec === 'gm') return gm;
    if (spec.startsWith('gm/')) {
      const verb = gm[spec.slice(3)];
      if (verb === undefined) throw new Error("Cannot find verb '" + spec.slice(3) + "'");
      return verb;
    }
    if (spec === 'fx:host') return loadedHost();
    if (spec.startsWith('tjs:')) {
      throw new Error("'" + spec + "' is not available in run_code; use gm.read_file, gm.write_file, gm.fs_read or gm.run_shell");
    }
    if (spec.startsWith('./') || spec.startsWith('../') || spec.startsWith('/')) {
      const target = spec.startsWith('/') ? spec : dir + '/' + spec;
      const resolved = resolveFile(normalize(target));
      if (resolved === null) throw new Error("Cannot find module '" + spec + "' from '" + dir + "'");
      return loadFile(resolved);
    }
    const resolved = callHost('fx.resolve', 'require\n' + dir + '/(require)\n' + spec);
    if (resolved.startsWith('!')) throw new Error(resolved.slice(1));
    if (resolved.startsWith('fx:host/')) return loadedHost().modules[resolved.slice('fx:host/'.length)];
    if (resolved.startsWith('freddie:')) throw new Error("'" + spec + "' is an ES module; use import instead of require");
    return loadFile(resolved);
  };
  const require = makeRequire(rootDir);
  return [gm, require];
})
