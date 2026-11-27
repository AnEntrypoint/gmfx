const std = @import("std");
const cordis = @import("cordis.zig");
const resolve = @import("resolve.zig");

pub const specifier = "fx:host";
pub const Error = error{ModuleNotProvided};

const node_prefix = "node:";
const runtime_module = cordis.prefix ++ "src/fx_runtime.js";

pub const Row = struct {
    name: []const u8,
    target: ?[]const u8 = null,
    member: []const u8 = "",
    source: []const u8 = "",
};

fn provided(comptime name: []const u8, comptime member: []const u8, comptime exports: []const []const u8) Row {
    return .{ .name = name, .target = specifier ++ "/" ++ name, .member = member, .source = moduleSource(name, exports) };
}

fn gap(comptime name: []const u8) Row {
    return .{ .name = name };
}

fn moduleSource(comptime name: []const u8, comptime exports: []const []const u8) []const u8 {
    const head = "import { modules } from '" ++ specifier ++ "'\nconst node = modules['" ++ name ++ "']\nexport default node\n";
    if (exports.len == 0) return head;
    comptime var named: []const u8 = exports[0];
    inline for (exports[1..]) |key| named = named ++ ", " ++ key;
    return head ++ "export const { " ++ named ++ " } = node\n";
}

pub const table = [_]Row{
    provided("async_hooks", "asyncHooks", &.{"AsyncLocalStorage"}),
    provided("buffer", "buffer", &.{ "Buffer", "constants" }),
    provided("child_process", "childProcess", &.{ "execFile", "execFileSync", "spawn", "spawnSync" }),
    provided("crypto", "crypto", &.{ "createHash", "randomBytes", "randomUUID" }),
    provided("dns/promises", "dnsPromises", &.{"lookup"}),
    provided("serve", "serveModule", &.{"serve"}),
    provided("pty", "ptyModule", &.{"spawn"}),
    provided("sqlite", "sqliteModule", &.{"open"}),
    provided("fetch", "fetchModule", &.{"fetch"}),
    provided("agent", "agentModule", &.{"core"}),
    provided("ws", "wsModule", &.{"connect"}),
    provided("loader", "loaderModule", &.{ "reload", "hotFor", "watchGraph", "current", "reloadCount", "rollback" }),
    provided("fs", "fs", &.{ "accessSync", "closeSync", "constants", "copyFileSync", "createReadStream", "existsSync", "lstatSync", "mkdirSync", "mkdtempSync", "openSync", "readFileSync", "readSync", "readdirSync", "readlinkSync", "realpathSync", "renameSync", "rmSync", "statSync", "symlinkSync", "unlinkSync", "unwatchFile", "watchFile", "writeFileSync", "writeSync" }),
    provided("fs/promises", "fsPromises", &.{ "access", "chmod", "constants", "cp", "link", "lstat", "mkdir", "mkdtemp", "open", "opendir", "readFile", "readdir", "realpath", "rename", "rm", "stat", "truncate", "unlink", "writeFile" }),
    provided("http", "http", &.{ "createServer", "validateHeaderValue" }),
    provided("https", "https", &.{ "createServer", "get", "request" }),
    provided("inspector", "inspector", &.{"Session"}),
    provided("module", "module", &.{ "createRequire", "stripTypeScriptTypes" }),
    provided("net", "net", &.{"isIP"}),
    provided("os", "os", &.{ "availableParallelism", "constants", "homedir", "networkInterfaces", "platform", "release", "tmpdir" }),
    provided("path", "path", &.{ "basename", "delimiter", "dirname", "extname", "format", "isAbsolute", "join", "normalize", "parse", "posix", "relative", "resolve", "sep", "toNamespacedPath", "win32" }),
    provided("perf_hooks", "perfHooks", &.{"performance"}),
    provided("process", "process", &.{}),
    provided("stream", "stream", &.{ "PassThrough", "Readable", "Writable", "pipeline" }),
    provided("string_decoder", "stringDecoder", &.{"StringDecoder"}),
    provided("timers/promises", "timersPromises", &.{ "scheduler", "setTimeout" }),
    provided("url", "url", &.{ "URL", "URLSearchParams", "fileURLToPath", "pathToFileURL" }),
    provided("util", "util", &.{ "TextDecoder", "inspect", "isDeepStrictEqual", "parseArgs", "parseEnv", "promisify" }),
    provided("util/types", "utilTypes", &.{"isPromise"}),
    provided("vm", "vm", &.{ "Script", "createContext", "runInContext" }),
    provided("worker_threads", "workerThreads", &.{ "MessageChannel", "Worker", "parentPort", "workerData" }),
    provided("zlib", "zlib", &.{ "brotliCompress", "constants", "createZstdDecompress", "deflate", "deflateSync", "gunzip", "gunzipSync", "gzip", "gzipSync", "inflate", "inflateSync", "zstdCompress", "zstdDecompress", "zstdDecompressSync" }),
};

comptime {
    @setEvalBranchQuota(20000);
    for (table, 0..) |row, index| {
        for (table[index + 1 ..]) |other| {
            if (std.mem.eql(u8, row.name, other.name)) @compileError("node module " ++ row.name ++ " has two alias rows");
        }
    }
}

const root_source = blk: {
    @setEvalBranchQuota(100_000);
    var entries: []const u8 = "";
    for (table) |row| {
        if (row.target != null) entries = entries ++ "  '" ++ row.name ++ "': fxRuntime." ++ row.member ++ ",\n";
    }
    break :blk "import { fxRuntime } from '" ++ runtime_module ++ "'\n" ++
        "const gm = globalThis.gm\n" ++
        "const catalog = gm.verbs()\n" ++
        "const pick = (kind) => Object.freeze(Object.fromEntries(catalog.filter((verb) => verb.kind === kind).map((verb) => [verb.name, gm[verb.name]])))\n" ++
        "export const version = Object.freeze({ interface: 1, minor: 0, host: 'fx' })\n" ++
        "export const tools = pick('tool')\n" ++
        "export const verbs = pick('host')\n" ++
        "export const modules = Object.freeze({\n" ++ entries ++ "})\n" ++
        "export const capabilities = Object.freeze(['tools', 'verbs', ...Object.keys(modules)])\n" ++
        "export default Object.freeze({ version, capabilities, tools, verbs, modules })\n";
};

pub fn target(name: []const u8) Error!?[]const u8 {
    const node = std.mem.startsWith(u8, name, node_prefix);
    const bare = if (node) name[node_prefix.len..] else name;
    for (table) |row| {
        if (std.mem.eql(u8, row.name, bare)) return row.target orelse error.ModuleNotProvided;
    }
    return if (node) error.ModuleNotProvided else null;
}

pub fn source(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, specifier)) return root_source;
    for (table) |row| {
        const found = row.target orelse continue;
        if (std.mem.eql(u8, found, name)) return row.source;
    }
    return null;
}

test "every alias row resolves its node: and bare names to one target through the resolver" {
    const alloc = std.testing.allocator;
    for (table) |row| {
        const node = try std.fmt.allocPrint(alloc, "node:{s}", .{row.name});
        defer alloc.free(node);
        inline for (.{ resolve.Mode.import, resolve.Mode.require }) |mode| {
            if (row.target) |expected| {
                const prefixed = try resolve.resolve(alloc, mode, "/nowhere/entry.js", node);
                defer alloc.free(prefixed);
                const bare = try resolve.resolve(alloc, mode, "/nowhere/entry.js", row.name);
                defer alloc.free(bare);
                try std.testing.expectEqualStrings(expected, prefixed);
                try std.testing.expectEqualStrings(expected, bare);
            } else {
                try std.testing.expectError(error.ModuleNotProvided, resolve.resolve(alloc, mode, "/nowhere/entry.js", node));
                try std.testing.expectError(error.ModuleNotProvided, resolve.resolve(alloc, mode, "/nowhere/entry.js", row.name));
            }
        }
    }
}

test "node:fs and fs resolve to the same fx:host module" {
    try std.testing.expectEqualStrings("fx:host/fs", (try target("node:fs")).?);
    try std.testing.expectEqualStrings("fx:host/fs", (try target("fs")).?);
}

test "an unknown node: name is the named not-provided error and an unknown bare name falls through to packages" {
    try std.testing.expectError(error.ModuleNotProvided, target("node:no_such_module"));
    try std.testing.expectEqual(@as(?[]const u8, null), try target("no_such_package"));
    const text = try resolve.reply(std.testing.allocator, "import\n/nowhere/entry.js\nnode:inspector");
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("!'node:inspector' is not provided by fx:host yet; it is on the gap list in docs/host-interface.md", text);
}

test "the alias table and the fx:host module list agree" {
    const runtime = cordis.source("src/fx_runtime.js").?;
    const runtime_object = runtime[std.mem.indexOf(u8, runtime, "export const fxRuntime = {").?..];
    for (table) |row| {
        const found = row.target orelse continue;
        try std.testing.expectEqualStrings(row.source, source(found).?);
        const entry = try std.fmt.allocPrint(std.testing.allocator, "  '{s}': fxRuntime.{s},\n", .{ row.name, row.member });
        defer std.testing.allocator.free(entry);
        try std.testing.expect(std.mem.indexOf(u8, root_source, entry) != null);
        const member = try std.fmt.allocPrint(std.testing.allocator, "\n  {s}", .{row.member});
        defer std.testing.allocator.free(member);
        try std.testing.expect(std.mem.indexOf(u8, runtime_object, member) != null);
    }
    try std.testing.expectEqual(@as(?[]const u8, null), source("fx:host/inspector"));
    try std.testing.expect(source(specifier) != null);
}
