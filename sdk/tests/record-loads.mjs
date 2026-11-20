


import { appendFileSync } from "node:fs";
import { registerHooks } from "node:module";

const log = process.env.LIBFX_LOAD_LOG;
if (log) {
  const seen = new Set();
  registerHooks({
    load(url, context, nextLoad) {
      if (!seen.has(url)) {
        seen.add(url);
        appendFileSync(log, `${url}\n`);
      }
      return nextLoad(url, context);
    },
  });
}
