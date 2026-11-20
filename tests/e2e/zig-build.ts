import { homedir } from "node:os";
import { join } from "node:path";



export function zigGlobalCacheDir(): string {
  if (process.env.ZIG_GLOBAL_CACHE_DIR) return process.env.ZIG_GLOBAL_CACHE_DIR;
  if (process.env.XDG_CACHE_HOME) return join(process.env.XDG_CACHE_HOME, "zig");
  return join(homedir(), ".cache", "zig");
}
