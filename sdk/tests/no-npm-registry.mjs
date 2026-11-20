






const fetch = globalThis.fetch;
globalThis.fetch = (input, init) => {
  const url = String(input instanceof Request ? input.url : input);
  if (url.startsWith("https://registry.npmjs.org/")) {
    return Promise.reject(new TypeError("test-next-package.mjs does not use the npm registry"));
  }
  return fetch(input, init);
};
