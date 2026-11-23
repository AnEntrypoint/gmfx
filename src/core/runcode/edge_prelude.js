const nodeIo = ['child_process', 'cluster', 'dgram', 'dns', 'fs', 'fs/promises', 'http', 'http2', 'https', 'inspector', 'net', 'tls', 'worker_threads'];
const refused = new Set(fxDenyNodeIo ? nodeIo : []);
const isRefused = (specifier) => refused.has(String(specifier).replace(/^node:/, ''));
const refusal = (specifier) => new Error("'" + specifier + "' is refused by the fx permission gate; use fxHost.call");
process.getBuiltinModule('module').registerHooks({
  resolve(specifier, context, next) {
    if (isRefused(specifier)) throw refusal(specifier);
    return next(specifier, context);
  },
});
if (fxDenyNodeIo) {
  const getBuiltinModule = process.getBuiltinModule;
  process.getBuiltinModule = function (specifier) {
    if (isRefused(specifier)) throw refusal(specifier);
    return getBuiltinModule.call(process, specifier);
  };
  process.binding = function (specifier) {
    throw refusal(specifier);
  };
}
