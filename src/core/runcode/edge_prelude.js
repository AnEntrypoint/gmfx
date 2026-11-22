const nodeIo = ['child_process', 'cluster', 'dgram', 'dns', 'fs', 'fs/promises', 'http', 'http2', 'https', 'inspector', 'net', 'tls', 'worker_threads'];
const refused = new Set(fxDenyNodeIo ? nodeIo : []);
process.getBuiltinModule('module').registerHooks({
  resolve(specifier, context, next) {
    if (refused.has(specifier.replace(/^node:/, ''))) throw new Error("'" + specifier + "' is refused by the fx permission gate; use fxHost.call");
    return next(specifier, context);
  },
});
