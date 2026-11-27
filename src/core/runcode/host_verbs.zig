const std = @import("std");
const url_policy = @import("../../tools/web/url_policy.zig");
const http_fetch = @import("../../tools/web/http_fetch.zig");
const net_serve = @import("net_serve.zig");
const pty_host = @import("pty_host.zig");
const sqlite_host = @import("sqlite_host.zig");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const model_tool_schema = @import("../tooling/model_tool_schema.zig");
const tool_args = @import("../tooling/tool_args.zig");

const Allocator = std.mem.Allocator;

pub const Verb = struct {
    name: []const u8,
    description: []const u8,
    input_schema: model_tool_schema.ObjectSchema = .{},
};

pub const verbs = [_]Verb{
    .{
        .name = "process_info",
        .description = "Report cwd, pid, platform, homedir, tmpdir, parallelism and env.",
    },
    .{
        .name = "net_fetch",
        .description = "Fetch an http(s) URL with an optional POST body; returns the status, final url and the body as base64. Loopback addresses need loopback: true.",
        .input_schema = .{
            .properties = &.{
                .{ .name = "url", .json_type = .string },
                .{ .name = "method", .json_type = .string },
                .{ .name = "body", .json_type = .string },
                .{ .name = "loopback", .json_type = .boolean },
            },
            .required = &.{"url"},
        },
    },
    .{
        .name = "proc_spawn",
        .description = "Start a process from file and args with piped stdin, stdout and stderr; returns its id.",
        .input_schema = .{
            .properties = &.{
                .{ .name = "file", .json_type = .string },
                .{ .name = "args", .json_type = .array },
                .{ .name = "cwd", .json_type = .string },
                .{ .name = "env_json", .json_type = .string },
            },
            .required = &.{"file"},
        },
    },
    .{
        .name = "proc_write",
        .description = "Write base64 bytes to a started process stdin.",
        .input_schema = .{
            .properties = &.{
                .{ .name = "id", .json_type = .integer },
                .{ .name = "body", .json_type = .string },
            },
            .required = &.{ "id", "body" },
        },
    },
    .{
        .name = "proc_close_stdin",
        .description = "Close a started process stdin.",
        .input_schema = .{
            .properties = &.{.{ .name = "id", .json_type = .integer }},
            .required = &.{"id"},
        },
    },
    .{
        .name = "proc_read",
        .description = "Read the next chunk of a started process stdout or stderr as base64; eof when closed.",
        .input_schema = .{
            .properties = &.{
                .{ .name = "id", .json_type = .integer },
                .{ .name = "stream", .json_type = .string },
            },
            .required = &.{"id"},
        },
    },
    .{
        .name = "proc_wait",
        .description = "Wait for a started process to exit and return its exit code.",
        .input_schema = .{
            .properties = &.{.{ .name = "id", .json_type = .integer }},
            .required = &.{"id"},
        },
    },
    .{
        .name = "proc_kill",
        .description = "Kill a started process.",
        .input_schema = .{
            .properties = &.{.{ .name = "id", .json_type = .integer }},
            .required = &.{"id"},
        },
    },
    .{
        .name = "dns_lookup",
        .description = "Resolve a public http(s) URL host to its first IPv4 address through the URL guard.",
        .input_schema = .{
            .properties = &.{.{ .name = "url", .json_type = .string }},
            .required = &.{"url"},
        },
    },
    .{
        .name = "watch_start",
        .description = "Start watching a directory for create, change, remove and rename events; returns its id.",
        .input_schema = .{
            .properties = &.{.{ .name = "path", .json_type = .string }},
            .required = &.{"path"},
        },
    },
    .{
        .name = "watch_poll",
        .description = "Wait up to timeout milliseconds for events on a watch and return them.",
        .input_schema = .{
            .properties = &.{
                .{ .name = "id", .json_type = .integer },
                .{ .name = "timeout", .json_type = .integer },
            },
            .required = &.{"id"},
        },
    },
    .{
        .name = "watch_close",
        .description = "Stop a watch.",
        .input_schema = .{
            .properties = &.{.{ .name = "id", .json_type = .integer }},
            .required = &.{"id"},
        },
    },
    .{
        .name = "serve_listen",
        .description = "Listen on a loopback address for HTTP and websocket connections; returns the server id and port.",
        .input_schema = .{
            .properties = &.{
                .{ .name = "url", .json_type = .string },
                .{ .name = "loopback", .json_type = .boolean },
                .{ .name = "host", .json_type = .string },
                .{ .name = "port", .json_type = .integer },
            },
            .required = &.{ "url", "host" },
        },
    },
    .{
        .name = "serve_accept",
        .description = "Accept the next connection on a server and read its HTTP request.",
        .input_schema = .{
            .properties = &.{.{ .name = "id", .json_type = .integer }},
            .required = &.{"id"},
        },
    },
    .{
        .name = "serve_respond",
        .description = "Send an HTTP response on a connection and close it.",
        .input_schema = .{
            .properties = &.{
                .{ .name = "conn", .json_type = .integer },
                .{ .name = "status", .json_type = .integer },
                .{ .name = "body", .json_type = .string },
            },
            .required = &.{ "conn", "status" },
        },
    },
    .{
        .name = "ws_send",
        .description = "Send a websocket text message on an upgraded connection.",
        .input_schema = .{
            .properties = &.{
                .{ .name = "conn", .json_type = .integer },
                .{ .name = "body", .json_type = .string },
            },
            .required = &.{ "conn", "body" },
        },
    },
    .{
        .name = "ws_recv",
        .description = "Receive the next websocket frame on an upgraded connection.",
        .input_schema = .{
            .properties = &.{.{ .name = "conn", .json_type = .integer }},
            .required = &.{"conn"},
        },
    },
    .{
        .name = "pty_spawn",
        .description = "Start a program on a pseudo-terminal; returns its id.",
        .input_schema = .{
            .properties = &.{
                .{ .name = "file", .json_type = .string },
                .{ .name = "args", .json_type = .array },
            },
            .required = &.{"file"},
        },
    },
    .{
        .name = "pty_write",
        .description = "Write base64 bytes to a pseudo-terminal.",
        .input_schema = .{
            .properties = &.{
                .{ .name = "id", .json_type = .integer },
                .{ .name = "body", .json_type = .string },
            },
            .required = &.{ "id", "body" },
        },
    },
    .{
        .name = "pty_read",
        .description = "Read the next output chunk of a pseudo-terminal as base64; eof when the program has exited.",
        .input_schema = .{
            .properties = &.{.{ .name = "id", .json_type = .integer }},
            .required = &.{"id"},
        },
    },
    .{
        .name = "pty_wait",
        .description = "Wait for a pseudo-terminal program to exit and return its exit code.",
        .input_schema = .{
            .properties = &.{.{ .name = "id", .json_type = .integer }},
            .required = &.{"id"},
        },
    },
    .{
        .name = "sqlite_open",
        .description = "Open or create a SQLite database file; returns its id.",
        .input_schema = .{
            .properties = &.{.{ .name = "path", .json_type = .string }},
            .required = &.{"path"},
        },
    },
    .{
        .name = "sqlite_exec",
        .description = "Run SQL on an open SQLite database.",
        .input_schema = .{
            .properties = &.{
                .{ .name = "id", .json_type = .integer },
                .{ .name = "sql", .json_type = .string },
            },
            .required = &.{ "id", "sql" },
        },
    },
    .{
        .name = "sqlite_all",
        .description = "Run a SQL query on an open SQLite database and return its rows as text.",
        .input_schema = .{
            .properties = &.{
                .{ .name = "id", .json_type = .integer },
                .{ .name = "sql", .json_type = .string },
            },
            .required = &.{ "id", "sql" },
        },
    },
    .{
        .name = "sqlite_close",
        .description = "Close an open SQLite database.",
        .input_schema = .{
            .properties = &.{.{ .name = "id", .json_type = .integer }},
            .required = &.{"id"},
        },
    },
    .{
        .name = "ws_connect",
        .description = "Open a websocket client to a loopback or public host; returns a connection id for ws_send and ws_recv.",
        .input_schema = .{
            .properties = &.{
                .{ .name = "url", .json_type = .string },
                .{ .name = "loopback", .json_type = .boolean },
                .{ .name = "path", .json_type = .string },
            },
            .required = &.{ "url", "path" },
        },
    },
    .{
        .name = "fs_exists",
        .description = "Report whether a path exists.",
        .input_schema = .{
            .properties = &.{
                .{ .name = "path", .json_type = .string },
            },
            .required = &.{"path"},
        },
    },
    .{
        .name = "fs_stat",
        .description = "Report type, size, mode and mtimeMs of a path.",
        .input_schema = .{
            .properties = &.{
                .{ .name = "path", .json_type = .string },
                .{ .name = "follow", .json_type = .boolean, .description = "Follow symlinks; default true." },
            },
            .required = &.{"path"},
        },
    },
    .{
        .name = "fs_read",
        .description = "Read a whole file as base64.",
        .input_schema = .{
            .properties = &.{
                .{ .name = "path", .json_type = .string },
            },
            .required = &.{"path"},
        },
    },
    .{
        .name = "fs_write",
        .description = "Write base64 bytes to a file, replacing it or appending.",
        .input_schema = .{
            .properties = &.{
                .{ .name = "path", .json_type = .string },
                .{ .name = "base64", .json_type = .string },
                .{ .name = "append", .json_type = .boolean },
            },
            .required = &.{ "path", "base64" },
        },
    },
    .{
        .name = "fs_read_range",
        .description = "Read length bytes from position as base64.",
        .input_schema = .{
            .properties = &.{
                .{ .name = "path", .json_type = .string },
                .{ .name = "position", .json_type = .integer },
                .{ .name = "length", .json_type = .integer },
            },
            .required = &.{ "path", "position", "length" },
        },
    },
    .{
        .name = "fs_write_at",
        .description = "Write base64 bytes at position, or at the end when position is null.",
        .input_schema = .{
            .properties = &.{
                .{ .name = "path", .json_type = .string },
                .{ .name = "base64", .json_type = .string },
                .{ .name = "position", .json_type = .integer },
            },
            .required = &.{ "path", "base64" },
        },
    },
    .{
        .name = "fs_readdir",
        .description = "List the entries of a directory.",
        .input_schema = .{
            .properties = &.{
                .{ .name = "path", .json_type = .string },
            },
            .required = &.{"path"},
        },
    },
    .{
        .name = "fs_mkdir",
        .description = "Create a directory.",
        .input_schema = .{
            .properties = &.{
                .{ .name = "path", .json_type = .string },
                .{ .name = "recursive", .json_type = .boolean },
            },
            .required = &.{"path"},
        },
    },
    .{
        .name = "fs_mkdtemp",
        .description = "Create a unique directory from a path prefix.",
        .input_schema = .{
            .properties = &.{
                .{ .name = "prefix", .json_type = .string },
            },
            .required = &.{"prefix"},
        },
    },
    .{
        .name = "fs_remove",
        .description = "Remove a file or directory.",
        .input_schema = .{
            .properties = &.{
                .{ .name = "path", .json_type = .string },
                .{ .name = "recursive", .json_type = .boolean },
                .{ .name = "force", .json_type = .boolean },
            },
            .required = &.{"path"},
        },
    },
    .{
        .name = "fs_rename",
        .description = "Rename a path.",
        .input_schema = .{
            .properties = &.{
                .{ .name = "from", .json_type = .string },
                .{ .name = "to", .json_type = .string },
            },
            .required = &.{ "from", "to" },
        },
    },
    .{
        .name = "fs_copy",
        .description = "Copy a file, or a tree when recursive.",
        .input_schema = .{
            .properties = &.{
                .{ .name = "from", .json_type = .string },
                .{ .name = "to", .json_type = .string },
                .{ .name = "recursive", .json_type = .boolean },
            },
            .required = &.{ "from", "to" },
        },
    },
    .{
        .name = "fs_realpath",
        .description = "Resolve a path to its canonical absolute form.",
        .input_schema = .{
            .properties = &.{
                .{ .name = "path", .json_type = .string },
            },
            .required = &.{"path"},
        },
    },
    .{
        .name = "fs_readlink",
        .description = "Read the target of a symlink.",
        .input_schema = .{
            .properties = &.{
                .{ .name = "path", .json_type = .string },
            },
            .required = &.{"path"},
        },
    },
    .{
        .name = "fs_symlink",
        .description = "Create a symlink at path pointing to target.",
        .input_schema = .{
            .properties = &.{
                .{ .name = "target", .json_type = .string },
                .{ .name = "path", .json_type = .string },
            },
            .required = &.{ "target", "path" },
        },
    },
    .{
        .name = "fs_link",
        .description = "Create a hard link at path to existing.",
        .input_schema = .{
            .properties = &.{
                .{ .name = "existing", .json_type = .string },
                .{ .name = "path", .json_type = .string },
            },
            .required = &.{ "existing", "path" },
        },
    },
    .{
        .name = "fs_chmod",
        .description = "Set the mode bits of a path.",
        .input_schema = .{
            .properties = &.{
                .{ .name = "path", .json_type = .string },
                .{ .name = "mode", .json_type = .integer },
            },
            .required = &.{ "path", "mode" },
        },
    },
    .{
        .name = "fs_truncate",
        .description = "Truncate a file to length bytes.",
        .input_schema = .{
            .properties = &.{
                .{ .name = "path", .json_type = .string },
                .{ .name = "length", .json_type = .integer },
            },
            .required = &.{ "path", "length" },
        },
    },
    .{
        .name = "run_command",
        .description = "Run a program without a shell; stdout and stderr come back as base64.",
        .input_schema = .{
            .properties = &.{
                .{ .name = "file", .json_type = .string },
                .{ .name = "args", .json_type = .array, .shape = &.{ .array_values = .{ .json_type = .string } } },
                .{ .name = "cwd", .json_type = .string },
                .{ .name = "env", .json_type = .object },
                .{ .name = "timeout_ms", .json_type = .integer },
                .{ .name = "input_base64", .json_type = .string, .description = "Standard input as base64; only an empty value is accepted in this build." },
            },
            .required = &.{"file"},
        },
    },
    .{
        .name = "random_bytes",
        .description = "Return n random bytes as base64.",
        .input_schema = .{
            .properties = &.{
                .{ .name = "n", .json_type = .integer },
            },
            .required = &.{"n"},
        },
    },
    .{
        .name = "hash_digest",
        .description = "Hash base64 bytes with sha1, sha256, sha512 or md5.",
        .input_schema = .{
            .properties = &.{
                .{ .name = "algorithm", .json_type = .string },
                .{ .name = "base64", .json_type = .string },
            },
            .required = &.{ "algorithm", "base64" },
        },
    },
};

pub const names = blk: {
    var list: [verbs.len][]const u8 = undefined;
    for (verbs, &list) |verb, *name| name.* = verb.name;
    const final = list;
    break :blk final;
};

const max_file_bytes: usize = 256 * 1024 * 1024;
const max_command_output_bytes: usize = 16 * 1024 * 1024;
const max_random_bytes: usize = 1024 * 1024;
const max_link_target_bytes: usize = 4096;
const max_copy_depth: usize = 64;

pub fn isHostVerb(name: []const u8) bool {
    for (names) |verb| {
        if (std.mem.eql(u8, verb, name)) return true;
    }
    return false;
}

pub fn call(alloc: Allocator, name: []const u8, args_json: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, args_json, .{}) catch {
        return invalid(alloc, "arguments must be valid JSON");
    };
    defer parsed.deinit();
    if (parsed.value != .object) return invalid(alloc, "arguments must be a JSON object");
    if (try unknownArgument(alloc, name, parsed.value.object)) |message| {
        defer alloc.free(message);
        return invalid(alloc, message);
    }
    return dispatch(alloc, name, parsed.value.object) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => failure(alloc, err),
    };
}

fn unknownArgument(alloc: Allocator, name: []const u8, args: std.json.ObjectMap) !?[]u8 {
    const verb = for (verbs) |entry| {
        if (std.mem.eql(u8, entry.name, name)) break entry;
    } else return null;
    const accepted = try alloc.alloc([]const u8, verb.input_schema.properties.len);
    defer alloc.free(accepted);
    for (verb.input_schema.properties, accepted) |property, *field| field.* = property.name;
    const key = tool_args.firstUnknownKey(args, accepted) orelse return null;
    return try tool_args.unknownArgumentMessage(alloc, name, key, accepted);
}

fn dispatch(alloc: Allocator, name: []const u8, args: std.json.ObjectMap) anyerror![]u8 {
    if (std.mem.eql(u8, name, "process_info")) return processInfo(alloc);
    if (std.mem.eql(u8, name, "fs_exists")) return fsExists(alloc, args);
    if (std.mem.eql(u8, name, "fs_stat")) return fsStat(alloc, args);
    if (std.mem.eql(u8, name, "fs_read")) return fsRead(alloc, args);
    if (std.mem.eql(u8, name, "fs_write")) return fsWrite(alloc, args);
    if (std.mem.eql(u8, name, "fs_read_range")) return fsReadRange(alloc, args);
    if (std.mem.eql(u8, name, "fs_write_at")) return fsWriteAt(alloc, args);
    if (std.mem.eql(u8, name, "fs_readdir")) return fsReaddir(alloc, args);
    if (std.mem.eql(u8, name, "fs_mkdir")) return fsMkdir(alloc, args);
    if (std.mem.eql(u8, name, "fs_mkdtemp")) return fsMkdtemp(alloc, args);
    if (std.mem.eql(u8, name, "fs_remove")) return fsRemove(alloc, args);
    if (std.mem.eql(u8, name, "fs_rename")) return fsRename(alloc, args);
    if (std.mem.eql(u8, name, "fs_copy")) return fsCopy(alloc, args);
    if (std.mem.eql(u8, name, "fs_realpath")) return fsRealpath(alloc, args);
    if (std.mem.eql(u8, name, "fs_readlink")) return fsReadlink(alloc, args);
    if (std.mem.eql(u8, name, "fs_symlink")) return fsSymlink(alloc, args);
    if (std.mem.eql(u8, name, "fs_link")) return fsLink(alloc, args);
    if (std.mem.eql(u8, name, "net_fetch")) return netFetch(alloc, args);
    if (std.mem.eql(u8, name, "dns_lookup")) return dnsLookup(alloc, args);
    if (std.mem.eql(u8, name, "watch_start")) return watchStart(alloc, args);
    if (std.mem.eql(u8, name, "watch_poll")) return watchPoll(alloc, args);
    if (std.mem.eql(u8, name, "watch_close")) return watchClose(alloc, args);
    if (std.mem.eql(u8, name, "serve_listen")) return serveListen(alloc, args);
    if (std.mem.eql(u8, name, "ws_connect")) return wsConnect(alloc, args);
    if (std.mem.eql(u8, name, "serve_accept")) return serveAccept(alloc, args);
    if (std.mem.eql(u8, name, "serve_respond")) return serveRespond(alloc, args);
    if (std.mem.eql(u8, name, "ws_send")) return wsSend(alloc, args);
    if (std.mem.eql(u8, name, "ws_recv")) return wsRecv(alloc, args);
    if (std.mem.eql(u8, name, "pty_spawn")) return ptySpawn(alloc, args);
    if (std.mem.eql(u8, name, "pty_write")) return ptyWrite(alloc, args);
    if (std.mem.eql(u8, name, "pty_read")) return ptyRead(alloc, args);
    if (std.mem.eql(u8, name, "pty_wait")) return ptyWait(alloc, args);
    if (std.mem.eql(u8, name, "sqlite_open")) return sqliteOpen(alloc, args);
    if (std.mem.eql(u8, name, "sqlite_exec")) return sqliteExec(alloc, args);
    if (std.mem.eql(u8, name, "sqlite_all")) return sqliteAll(alloc, args);
    if (std.mem.eql(u8, name, "sqlite_close")) return sqliteClose(alloc, args);
    if (std.mem.eql(u8, name, "proc_spawn")) return procSpawn(alloc, args);
    if (std.mem.eql(u8, name, "proc_write")) return procWrite(alloc, args);
    if (std.mem.eql(u8, name, "proc_close_stdin")) return procCloseStdin(alloc, args);
    if (std.mem.eql(u8, name, "proc_read")) return procRead(alloc, args);
    if (std.mem.eql(u8, name, "proc_wait")) return procWait(alloc, args);
    if (std.mem.eql(u8, name, "proc_kill")) return procKill(alloc, args);
    if (std.mem.eql(u8, name, "fs_chmod")) return fsChmod(alloc, args);
    if (std.mem.eql(u8, name, "fs_truncate")) return fsTruncate(alloc, args);
    if (std.mem.eql(u8, name, "run_command")) return runCommand(alloc, args);
    if (std.mem.eql(u8, name, "random_bytes")) return randomBytes(alloc, args);
    if (std.mem.eql(u8, name, "hash_digest")) return hashDigest(alloc, args);
    return invalid(alloc, "unknown host verb");
}

fn stringArg(args: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = args.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn integerArg(args: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = args.get(key) orelse return null;
    return switch (value) {
        .integer => |number| number,
        else => null,
    };
}

fn nonNegativeArg(args: std.json.ObjectMap, key: []const u8) ?u64 {
    const number = integerArg(args, key) orelse return null;
    return std.math.cast(u64, number);
}

fn boolArg(args: std.json.ObjectMap, key: []const u8, default: bool) bool {
    const value = args.get(key) orelse return default;
    return switch (value) {
        .bool => |flag| flag,
        else => default,
    };
}

fn encode(alloc: Allocator, value: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}

const Failure = struct {
    ok: bool = false,
    code: []const u8,
    @"error": []const u8,
};

fn invalid(alloc: Allocator, message: []const u8) ![]u8 {
    return encode(alloc, Failure{ .code = "EINVAL", .@"error" = message });
}

fn invalidField(alloc: Allocator, field: []const u8, expected: []const u8) ![]u8 {
    const message = try std.fmt.allocPrint(alloc, "field \"{s}\" must be {s}", .{ field, expected });
    defer alloc.free(message);
    return encode(alloc, Failure{ .code = "EINVAL", .@"error" = message });
}

fn failure(alloc: Allocator, err: anyerror) ![]u8 {
    return encode(alloc, Failure{ .code = errorCode(err), .@"error" = @errorName(err) });
}

fn errorCode(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "ENOENT",
        error.PathAlreadyExists => "EEXIST",
        error.NotDir => "ENOTDIR",
        error.IsDir => "EISDIR",
        error.AccessDenied, error.PermissionDenied => "EACCES",
        error.DirNotEmpty => "ENOTEMPTY",
        error.Timeout => "ETIMEDOUT",
        error.StreamTooLong => "ENOBUFS",
        error.SymLinkLoop => "ELOOP",
        error.NameTooLong => "ENAMETOOLONG",
        else => "EIO",
    };
}

fn kindName(kind: std.Io.File.Kind) []const u8 {
    return switch (kind) {
        .file => "file",
        .directory => "directory",
        .sym_link => "symlink",
        else => "other",
    };
}

fn encodeBase64(alloc: Allocator, bytes: []const u8) ![]u8 {
    const encoder = std.base64.standard.Encoder;
    const out = try alloc.alloc(u8, encoder.calcSize(bytes.len));
    _ = encoder.encode(out, bytes);
    return out;
}

fn decodeBase64(alloc: Allocator, text: []const u8) ![]u8 {
    const decoder = std.base64.standard.Decoder;
    const size = try decoder.calcSizeForSlice(text);
    const out = try alloc.alloc(u8, size);
    errdefer alloc.free(out);
    try decoder.decode(out, text);
    return out;
}

fn base64Arg(alloc: Allocator, args: std.json.ObjectMap) !union(enum) { bytes: []u8, reply: []u8 } {
    const text = stringArg(args, "base64") orelse return .{ .reply = try invalidField(alloc, "base64", "a base64 string") };
    const bytes = decodeBase64(alloc, text) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .{ .reply = try invalidField(alloc, "base64", "valid base64") },
    };
    return .{ .bytes = bytes };
}

fn writeField(out: *std.Io.Writer.Allocating, first: *bool, key: []const u8, value: anytype) !void {
    if (!first.*) try out.writer.writeByte(',');
    first.* = false;
    try std.json.Stringify.value(key, .{}, &out.writer);
    try out.writer.writeByte(':');
    try std.json.Stringify.value(value, .{}, &out.writer);
}

fn nodePlatform() []const u8 {
    return switch (builtin.target.os.tag) {
        .macos => "darwin",
        .windows => "win32",
        else => @tagName(builtin.target.os.tag),
    };
}

fn processInfo(alloc: Allocator) anyerror![]u8 {
    const io = io_mod.getIo();
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", alloc);
    defer alloc.free(cwd);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"ok\":true");
    var first = false;
    try writeField(&out, &first, "cwd", cwd);
    try writeField(&out, &first, "argv", [_][]const u8{});
    try writeField(&out, &first, "pid", std.c.getpid());
    try writeField(&out, &first, "platform", nodePlatform());
    try writeField(&out, &first, "version", "");
    try writeField(&out, &first, "release", "");
    try writeField(&out, &first, "homedir", io_mod.homeDir() orelse "");
    try writeField(&out, &first, "tmpdir", io_mod.getenv("TMPDIR") orelse "/tmp");
    try writeField(&out, &first, "parallelism", std.Thread.getCpuCount() catch 1);
    try out.writer.writeAll(",\"env\":{");
    if (io_mod.environMap()) |map| {
        for (map.array_hash_map.keys(), map.array_hash_map.values(), 0..) |key, value, index| {
            if (index > 0) try out.writer.writeByte(',');
            try std.json.Stringify.value(key, .{}, &out.writer);
            try out.writer.writeByte(':');
            try std.json.Stringify.value(value, .{}, &out.writer);
        }
    }
    try out.writer.writeAll("}}");
    return out.toOwnedSlice();
}

fn fsExists(alloc: Allocator, args: std.json.ObjectMap) anyerror![]u8 {
    const path = stringArg(args, "path") orelse return invalidField(alloc, "path", "a string");
    const io = io_mod.getIo();
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return encode(alloc, .{ .ok = true, .exists = false }),
        else => return err,
    };
    return encode(alloc, .{ .ok = true, .exists = true });
}

fn netFetch(alloc: Allocator, args: std.json.ObjectMap) anyerror![]u8 {
    const url_text = stringArg(args, "url") orelse return invalidField(alloc, "url", "a string");
    const method = stringArg(args, "method") orelse "GET";
    const post = std.mem.eql(u8, method, "POST");
    if (!post and !std.mem.eql(u8, method, "GET")) return invalidField(alloc, "method", "GET or POST");
    const post_body: ?[]u8 = if (post) blk: {
        const encoded = stringArg(args, "body") orelse "";
        const size = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
        const out = try alloc.alloc(u8, size);
        try std.base64.standard.Decoder.decode(out, encoded);
        break :blk out;
    } else null;
    defer if (post_body) |body| alloc.free(body);
    const loopback = boolArg(args, "loopback", false);
    var validated = url_policy.normalizeWith(alloc, url_text, loopback) catch |err| {
        const message = switch (err) {
            error.NonPublicAddress, error.SingleLabelHost => "web_fetch only fetches known public HTTP(S) URLs",
            else => @errorName(err),
        };
        return encode(alloc, .{ .ok = false, .@"error" = message });
    };
    defer validated.deinit(alloc);
    var outcome = try http_fetch.fetch(alloc, validated, .{ .post_body = post_body, .allow_loopback = loopback }, http_fetch.defaultTransport());
    defer outcome.deinit(alloc);
    switch (outcome) {
        .success => |*success| {
            const encoded = try alloc.alloc(u8, std.base64.standard.Encoder.calcSize(success.body.len));
            defer alloc.free(encoded);
            _ = std.base64.standard.Encoder.encode(encoded, success.body);
            return encode(alloc, .{ .ok = true, .status = @intFromEnum(success.status), .url = success.final_url, .body = @as([]const u8, encoded) });
        },
        .failure => |*failed| return encode(alloc, .{ .ok = true, .status = if (failed.status) |status| @intFromEnum(status) else 0, .url = url_text, .body = "" }),
        .cross_host_redirect => return encode(alloc, .{ .ok = false, .@"error" = "cross_host_redirect" }),
    }
}

const Proc = struct {
    child: std.process.Child,
    out_buf: std.ArrayList(u8) = .empty,
    err_buf: std.ArrayList(u8) = .empty,
    out_eof: bool = false,
    err_eof: bool = false,
};
var procs: std.AutoHashMapUnmanaged(i64, Proc) = .empty;
var next_proc_id: i64 = 1;
const proc_store = std.heap.page_allocator;

fn procFor(args: std.json.ObjectMap) ?*Proc {
    const id = integerArg(args, "id") orelse return null;
    return procs.getPtr(id);
}

fn procRelease(id: i64) void {
    const entry = procs.fetchRemove(id) orelse return;
    var proc = entry.value;
    proc.out_buf.deinit(proc_store);
    proc.err_buf.deinit(proc_store);
}

fn pumpOnce(proc: *Proc) anyerror!bool {
    var fds: [2]std.posix.pollfd = undefined;
    var is_stderr: [2]bool = undefined;
    var count: usize = 0;
    if (proc.child.stdout) |out| {
        if (!proc.out_eof) {
            fds[count] = .{ .fd = out.handle, .events = std.posix.POLL.IN, .revents = 0 };
            is_stderr[count] = false;
            count += 1;
        }
    }
    if (proc.child.stderr) |err_file| {
        if (!proc.err_eof) {
            fds[count] = .{ .fd = err_file.handle, .events = std.posix.POLL.IN, .revents = 0 };
            is_stderr[count] = true;
            count += 1;
        }
    }
    if (count == 0) return false;
    _ = try std.posix.poll(fds[0..count], -1);
    for (0..count) |index| {
        if (fds[index].revents == 0) continue;
        var chunk: [16384]u8 = undefined;
        const read_len = try std.posix.read(fds[index].fd, &chunk);
        if (is_stderr[index]) {
            if (read_len == 0) proc.err_eof = true else try proc.err_buf.appendSlice(proc_store, chunk[0..read_len]);
        } else {
            if (read_len == 0) proc.out_eof = true else try proc.out_buf.appendSlice(proc_store, chunk[0..read_len]);
        }
    }
    return true;
}

fn procSpawn(alloc: Allocator, args: std.json.ObjectMap) anyerror![]u8 {
    const file = stringArg(args, "file") orelse return invalidField(alloc, "file", "a string");
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    try argv.append(alloc, file);
    if (args.get("args")) |value| switch (value) {
        .array => |items| for (items.items) |item| switch (item) {
            .string => |text| try argv.append(alloc, text),
            else => return invalidField(alloc, "args", "an array of strings"),
        },
        else => return invalidField(alloc, "args", "an array of strings"),
    };
    var environment = std.process.Environ.Map.init(proc_store);
    defer environment.deinit();
    var env_parsed: ?std.json.Parsed(std.json.Value) = if (stringArg(args, "env_json")) |text|
        try std.json.parseFromSlice(std.json.Value, alloc, text, .{})
    else
        null;
    defer if (env_parsed) |*parsed| parsed.deinit();
    const has_env = if (env_parsed) |parsed| blk: {
        switch (parsed.value) {
            .object => |entries| {
                var iterator = entries.iterator();
                while (iterator.next()) |entry| switch (entry.value_ptr.*) {
                    .string => |text| try environment.put(entry.key_ptr.*, text),
                    else => return invalidField(alloc, "env", "an object of strings"),
                };
            },
            else => return invalidField(alloc, "env", "an object of strings"),
        }
        break :blk true;
    } else false;
    const env_ptr: ?*const std.process.Environ.Map = if (has_env) &environment else null;
    const cwd_text = stringArg(args, "cwd");
    const child = (if (cwd_text) |dir| std.process.spawn(io_mod.getIo(), .{
        .argv = argv.items,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
        .cwd = .{ .path = dir },
        .environ_map = env_ptr,
    }) else std.process.spawn(io_mod.getIo(), .{
        .argv = argv.items,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
        .environ_map = env_ptr,
    })) catch |err| return encode(alloc, .{ .ok = false, .@"error" = @errorName(err) });
    const id = next_proc_id;
    next_proc_id += 1;
    try procs.put(proc_store, id, .{ .child = child });
    return encode(alloc, .{ .ok = true, .id = id });
}

fn procWrite(alloc: Allocator, args: std.json.ObjectMap) anyerror![]u8 {
    const proc = procFor(args) orelse return encode(alloc, .{ .ok = false, .@"error" = "no such process" });
    const stdin_file = proc.child.stdin orelse return encode(alloc, .{ .ok = false, .@"error" = "stdin is closed" });
    const encoded = stringArg(args, "body") orelse "";
    const size = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
    const bytes = try alloc.alloc(u8, size);
    defer alloc.free(bytes);
    try std.base64.standard.Decoder.decode(bytes, encoded);
    try stdin_file.writeStreamingAll(io_mod.getIo(), bytes);
    return encode(alloc, .{ .ok = true });
}

fn procCloseStdin(alloc: Allocator, args: std.json.ObjectMap) anyerror![]u8 {
    const proc = procFor(args) orelse return encode(alloc, .{ .ok = false, .@"error" = "no such process" });
    if (proc.child.stdin) |stdin_file| {
        stdin_file.close(io_mod.getIo());
        proc.child.stdin = null;
    }
    return encode(alloc, .{ .ok = true });
}

fn procRead(alloc: Allocator, args: std.json.ObjectMap) anyerror![]u8 {
    const proc = procFor(args) orelse return encode(alloc, .{ .ok = false, .@"error" = "no such process" });
    const is_stderr = std.mem.eql(u8, stringArg(args, "stream") orelse "stdout", "stderr");
    while (true) {
        const buf = if (is_stderr) &proc.err_buf else &proc.out_buf;
        const done = if (is_stderr) proc.err_eof else proc.out_eof;
        if (buf.items.len > 0 or done) break;
        if (!try pumpOnce(proc)) {
            if (is_stderr) proc.err_eof = true else proc.out_eof = true;
        }
    }
    const buf = if (is_stderr) &proc.err_buf else &proc.out_buf;
    if (buf.items.len == 0) return encode(alloc, .{ .ok = true, .eof = true, .body = "" });
    const encoded = try alloc.alloc(u8, std.base64.standard.Encoder.calcSize(buf.items.len));
    defer alloc.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, buf.items);
    buf.clearRetainingCapacity();
    return encode(alloc, .{ .ok = true, .eof = false, .body = @as([]const u8, encoded) });
}

fn procWait(alloc: Allocator, args: std.json.ObjectMap) anyerror![]u8 {
    const id = integerArg(args, "id") orelse return invalidField(alloc, "id", "an integer");
    const proc = procFor(args) orelse return encode(alloc, .{ .ok = false, .@"error" = "no such process" });
    while (!(proc.out_eof and proc.err_eof)) {
        if (!try pumpOnce(proc)) break;
    }
    const term = try proc.child.wait(io_mod.getIo());
    const code: i64 = switch (term) {
        .exited => |value| @as(i64, value),
        else => -1,
    };
    procRelease(id);
    return encode(alloc, .{ .ok = true, .code = code });
}

fn procKill(alloc: Allocator, args: std.json.ObjectMap) anyerror![]u8 {
    const id = integerArg(args, "id") orelse return invalidField(alloc, "id", "an integer");
    const proc = procFor(args) orelse return encode(alloc, .{ .ok = false, .@"error" = "no such process" });
    proc.child.kill(io_mod.getIo());
    procRelease(id);
    return encode(alloc, .{ .ok = true });
}

fn dnsLookup(alloc: Allocator, args: std.json.ObjectMap) anyerror![]u8 {
    const url_text = stringArg(args, "url") orelse return invalidField(alloc, "url", "a string");
    var validated = url_policy.normalizeWith(alloc, url_text, false) catch |err| return encode(alloc, .{ .ok = false, .@"error" = @errorName(err) });
    defer validated.deinit(alloc);
    const transport = http_fetch.defaultTransport();
    const addresses = try transport.resolver.resolve(transport.resolver.ctx, alloc, validated.canonical_host, 443, .{});
    defer alloc.free(addresses);
    if (addresses.len == 0) return encode(alloc, .{ .ok = false, .@"error" = "no address returned" });
    return switch (addresses[0]) {
        .ip4 => |ip4| blk: {
            const text = try std.fmt.allocPrint(alloc, "{d}.{d}.{d}.{d}", .{ ip4.bytes[0], ip4.bytes[1], ip4.bytes[2], ip4.bytes[3] });
            defer alloc.free(text);
            break :blk encode(alloc, .{ .ok = true, .address = text, .family = @as(i64, 4) });
        },
        .ip6 => encode(alloc, .{ .ok = false, .@"error" = "ipv6 answers are not returned yet" }),
    };
}

const WatchEntry = struct { fd: i32, path: []u8 };
var watches: std.AutoHashMapUnmanaged(i64, WatchEntry) = .empty;
var next_watch_id: i64 = 1;
const watch_store = std.heap.page_allocator;
const watch_mask: u32 = std.os.linux.IN.CREATE | std.os.linux.IN.MODIFY | std.os.linux.IN.DELETE | std.os.linux.IN.MOVED_FROM | std.os.linux.IN.MOVED_TO;

const WatchEvent = struct { kind: []const u8, name: []const u8 };

fn watchStart(alloc: Allocator, args: std.json.ObjectMap) anyerror![]u8 {
    const path = stringArg(args, "path") orelse return invalidField(alloc, "path", "a string");
    const fd_rc = std.os.linux.inotify_init1(std.os.linux.IN.CLOEXEC | std.os.linux.IN.NONBLOCK);
    if (std.os.linux.errno(fd_rc) != .SUCCESS) return encode(alloc, .{ .ok = false, .@"error" = "inotify_init1 failed" });
    const fd: i32 = @intCast(fd_rc);
    const path_z = try watch_store.dupeSentinel(u8, path, 0);
    defer watch_store.free(path_z);
    const add_rc = std.os.linux.inotify_add_watch(fd, path_z, watch_mask);
    if (std.os.linux.errno(add_rc) != .SUCCESS) {
        _ = std.os.linux.close(fd);
        return encode(alloc, .{ .ok = false, .@"error" = "inotify_add_watch failed" });
    }
    const id = next_watch_id;
    next_watch_id += 1;
    try watches.put(watch_store, id, .{ .fd = fd, .path = try watch_store.dupe(u8, path) });
    return encode(alloc, .{ .ok = true, .id = id });
}

fn watchKindOf(mask: u32) []const u8 {
    if (mask & std.os.linux.IN.CREATE != 0) return "create";
    if (mask & std.os.linux.IN.DELETE != 0) return "remove";
    if (mask & (std.os.linux.IN.MOVED_FROM | std.os.linux.IN.MOVED_TO) != 0) return "rename";
    return "change";
}

fn watchPoll(alloc: Allocator, args: std.json.ObjectMap) anyerror![]u8 {
    const id = integerArg(args, "id") orelse return invalidField(alloc, "id", "an integer");
    const entry = watches.get(id) orelse return encode(alloc, .{ .ok = false, .@"error" = "no such watch" });
    const timeout: i32 = @intCast(integerArg(args, "timeout") orelse 1000);
    var fds = [_]std.posix.pollfd{.{ .fd = entry.fd, .events = std.posix.POLL.IN, .revents = 0 }};
    _ = try std.posix.poll(&fds, timeout);
    var events: std.ArrayList(WatchEvent) = .empty;
    defer events.deinit(alloc);
    var buffer: [4096]u8 = undefined;
    const read_rc = std.os.linux.read(entry.fd, &buffer, buffer.len);
    if (std.os.linux.errno(read_rc) == .SUCCESS) {
        const count: usize = read_rc;
        var offset: usize = 0;
        while (offset + 16 <= count) {
            const mask = std.mem.readInt(u32, buffer[offset + 4 ..][0..4], .little);
            const name_len = std.mem.readInt(u32, buffer[offset + 12 ..][0..4], .little);
            const name_raw = buffer[offset + 16 .. offset + 16 + name_len];
            const name = std.mem.sliceTo(name_raw, 0);
            try events.append(alloc, .{ .kind = watchKindOf(mask), .name = name });
            offset += 16 + name_len;
        }
    }
    return encode(alloc, .{ .ok = true, .events = events.items });
}

fn watchClose(alloc: Allocator, args: std.json.ObjectMap) anyerror![]u8 {
    const id = integerArg(args, "id") orelse return invalidField(alloc, "id", "an integer");
    const entry = watches.fetchRemove(id) orelse return encode(alloc, .{ .ok = false, .@"error" = "no such watch" });
    _ = std.os.linux.close(entry.value.fd);
    watch_store.free(entry.value.path);
    return encode(alloc, .{ .ok = true });
}

var servers: std.AutoHashMapUnmanaged(i64, *std.Io.net.Server) = .empty;
var serve_conns: std.AutoHashMapUnmanaged(i64, *net_serve.Conn) = .empty;
var next_serve_id: i64 = 1;
const serve_store = std.heap.page_allocator;

fn serveListen(alloc: Allocator, args: std.json.ObjectMap) anyerror![]u8 {
    const bind = stringArg(args, "host") orelse return invalidField(alloc, "host", "a string");
    const port: u16 = @intCast(integerArg(args, "port") orelse 0);
    const server = net_serve.listen(serve_store, io_mod.getIo(), bind, port) catch |err| return encode(alloc, .{ .ok = false, .@"error" = @errorName(err) });
    const id = next_serve_id;
    next_serve_id += 1;
    try servers.put(serve_store, id, server);
    return encode(alloc, .{ .ok = true, .id = id, .port = @as(i64, server.socket.address.getPort()) });
}

fn serveAccept(alloc: Allocator, args: std.json.ObjectMap) anyerror![]u8 {
    const id = integerArg(args, "id") orelse return invalidField(alloc, "id", "an integer");
    const server = servers.get(id) orelse return encode(alloc, .{ .ok = false, .@"error" = "no such server" });
    const conn = try net_serve.accept(serve_store, io_mod.getIo(), server);
    var request = net_serve.readRequest(serve_store, io_mod.getIo(), conn) catch |err| {
        conn.stream.close(io_mod.getIo());
        serve_store.destroy(conn);
        return encode(alloc, .{ .ok = false, .@"error" = @errorName(err) });
    };
    defer request.deinit(serve_store);
    const conn_id = next_serve_id;
    next_serve_id += 1;
    try serve_conns.put(serve_store, conn_id, conn);
    if (request.upgrade) try net_serve.upgrade(io_mod.getIo(), conn, request.key);
    return encode(alloc, .{ .ok = true, .conn = conn_id, .method = request.method, .path = request.path, .upgrade = request.upgrade, .body = request.body });
}

fn serveRespond(alloc: Allocator, args: std.json.ObjectMap) anyerror![]u8 {
    const id = integerArg(args, "conn") orelse return invalidField(alloc, "conn", "an integer");
    const status = integerArg(args, "status") orelse 200;
    const body = stringArg(args, "body") orelse "";
    const entry = serve_conns.fetchRemove(id) orelse return encode(alloc, .{ .ok = false, .@"error" = "no such connection" });
    try net_serve.respond(serve_store, io_mod.getIo(), entry.value, @intCast(status), body);
    serve_store.destroy(entry.value);
    return encode(alloc, .{ .ok = true });
}

fn wsSend(alloc: Allocator, args: std.json.ObjectMap) anyerror![]u8 {
    const id = integerArg(args, "conn") orelse return invalidField(alloc, "conn", "an integer");
    const conn = serve_conns.get(id) orelse return encode(alloc, .{ .ok = false, .@"error" = "no such connection" });
    try net_serve.wsSend(io_mod.getIo(), conn, stringArg(args, "body") orelse "");
    return encode(alloc, .{ .ok = true });
}

fn wsConnect(alloc: Allocator, args: std.json.ObjectMap) anyerror![]u8 {
    const url_text = stringArg(args, "url") orelse return invalidField(alloc, "url", "a string");
    const path = stringArg(args, "path") orelse return invalidField(alloc, "path", "a string");
    var validated = url_policy.normalizeWith(alloc, url_text, boolArg(args, "loopback", false)) catch |err| return encode(alloc, .{ .ok = false, .@"error" = @errorName(err) });
    defer validated.deinit(alloc);
    const conn = net_serve.connect(serve_store, io_mod.getIo(), validated.canonical_host, validated.port, path) catch |err| return encode(alloc, .{ .ok = false, .@"error" = @errorName(err) });
    const id = next_serve_id;
    next_serve_id += 1;
    try serve_conns.put(serve_store, id, conn);
    return encode(alloc, .{ .ok = true, .conn = id });
}

fn wsRecv(alloc: Allocator, args: std.json.ObjectMap) anyerror![]u8 {
    const id = integerArg(args, "conn") orelse return invalidField(alloc, "conn", "an integer");
    const conn = serve_conns.get(id) orelse return encode(alloc, .{ .ok = false, .@"error" = "no such connection" });
    const frame = try net_serve.wsRecv(serve_store, io_mod.getIo(), conn);
    defer serve_store.free(frame.payload);
    return encode(alloc, .{ .ok = true, .opcode = @as(i64, frame.opcode), .body = frame.payload });
}

var ptys: std.AutoHashMapUnmanaged(i64, pty_host.Session) = .empty;
var next_pty_id: i64 = 1;
const pty_store = std.heap.page_allocator;

fn ptySpawn(alloc: Allocator, args: std.json.ObjectMap) anyerror![]u8 {
    const file = stringArg(args, "file") orelse return invalidField(alloc, "file", "a string");
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    try argv.append(alloc, file);
    if (args.get("args")) |value| switch (value) {
        .array => |items| for (items.items) |item| switch (item) {
            .string => |text| try argv.append(alloc, text),
            else => return invalidField(alloc, "args", "an array of strings"),
        },
        else => return invalidField(alloc, "args", "an array of strings"),
    };
    const session = pty_host.spawn(io_mod.getIo(), argv.items) catch |err| return encode(alloc, .{ .ok = false, .@"error" = @errorName(err) });
    const id = next_pty_id;
    next_pty_id += 1;
    try ptys.put(pty_store, id, session);
    return encode(alloc, .{ .ok = true, .id = id });
}

fn ptyWrite(alloc: Allocator, args: std.json.ObjectMap) anyerror![]u8 {
    const id = integerArg(args, "id") orelse return invalidField(alloc, "id", "an integer");
    const session = ptys.get(id) orelse return encode(alloc, .{ .ok = false, .@"error" = "no such terminal" });
    const encoded = stringArg(args, "body") orelse "";
    const size = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
    const bytes = try alloc.alloc(u8, size);
    defer alloc.free(bytes);
    try std.base64.standard.Decoder.decode(bytes, encoded);
    try pty_host.write(io_mod.getIo(), session.master, bytes);
    return encode(alloc, .{ .ok = true });
}

fn ptyRead(alloc: Allocator, args: std.json.ObjectMap) anyerror![]u8 {
    const id = integerArg(args, "id") orelse return invalidField(alloc, "id", "an integer");
    const session = ptys.get(id) orelse return encode(alloc, .{ .ok = false, .@"error" = "no such terminal" });
    var buffer: [4096]u8 = undefined;
    const count = try pty_host.read(session.master, &buffer);
    if (count == 0) return encode(alloc, .{ .ok = true, .eof = true, .body = "" });
    const encoded = try alloc.alloc(u8, std.base64.standard.Encoder.calcSize(count));
    defer alloc.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, buffer[0..count]);
    return encode(alloc, .{ .ok = true, .eof = false, .body = @as([]const u8, encoded) });
}

fn ptyWait(alloc: Allocator, args: std.json.ObjectMap) anyerror![]u8 {
    const id = integerArg(args, "id") orelse return invalidField(alloc, "id", "an integer");
    const entry = ptys.fetchRemove(id) orelse return encode(alloc, .{ .ok = false, .@"error" = "no such terminal" });
    var session = entry.value;
    const term = try session.child.wait(io_mod.getIo());
    _ = std.c.close(session.master);
    const code: i64 = switch (term) {
        .exited => |value| @as(i64, value),
        else => -1,
    };
    return encode(alloc, .{ .ok = true, .code = code });
}

var sqlite_dbs: std.AutoHashMapUnmanaged(i64, *sqlite_host.c.sqlite3) = .empty;
var next_sqlite_id: i64 = 1;
const sqlite_store = std.heap.page_allocator;

fn sqliteOpen(alloc: Allocator, args: std.json.ObjectMap) anyerror![]u8 {
    const path = stringArg(args, "path") orelse return invalidField(alloc, "path", "a string");
    const path_z = try sqlite_store.dupeSentinel(u8, path, 0);
    defer sqlite_store.free(path_z);
    const db = sqlite_host.open(path_z) catch |err| return encode(alloc, .{ .ok = false, .@"error" = @errorName(err) });
    const id = next_sqlite_id;
    next_sqlite_id += 1;
    try sqlite_dbs.put(sqlite_store, id, db);
    return encode(alloc, .{ .ok = true, .id = id });
}

fn sqliteExec(alloc: Allocator, args: std.json.ObjectMap) anyerror![]u8 {
    const id = integerArg(args, "id") orelse return invalidField(alloc, "id", "an integer");
    const db = sqlite_dbs.get(id) orelse return encode(alloc, .{ .ok = false, .@"error" = "no such database" });
    const sql = try sqlite_store.dupeSentinel(u8, stringArg(args, "sql") orelse "", 0);
    defer sqlite_store.free(sql);
    sqlite_host.exec(db, sql) catch |err| return encode(alloc, .{ .ok = false, .@"error" = @errorName(err) });
    return encode(alloc, .{ .ok = true });
}

fn sqliteAll(alloc: Allocator, args: std.json.ObjectMap) anyerror![]u8 {
    const id = integerArg(args, "id") orelse return invalidField(alloc, "id", "an integer");
    const db = sqlite_dbs.get(id) orelse return encode(alloc, .{ .ok = false, .@"error" = "no such database" });
    const sql = try sqlite_store.dupeSentinel(u8, stringArg(args, "sql") orelse "", 0);
    defer sqlite_store.free(sql);
    const rows = sqlite_host.all(alloc, db, sql) catch |err| return encode(alloc, .{ .ok = false, .@"error" = @errorName(err) });
    defer {
        for (rows) |row| {
            for (row) |cell| alloc.free(cell);
            alloc.free(row);
        }
        alloc.free(rows);
    }
    return encode(alloc, .{ .ok = true, .rows = rows });
}

fn sqliteClose(alloc: Allocator, args: std.json.ObjectMap) anyerror![]u8 {
    const id = integerArg(args, "id") orelse return invalidField(alloc, "id", "an integer");
    const entry = sqlite_dbs.fetchRemove(id) orelse return encode(alloc, .{ .ok = false, .@"error" = "no such database" });
    sqlite_host.close(entry.value);
    return encode(alloc, .{ .ok = true });
}

fn fsStat(alloc: Allocator, args: std.json.ObjectMap) anyerror![]u8 {
    const path = stringArg(args, "path") orelse return invalidField(alloc, "path", "a string");
    const follow = boolArg(args, "follow", true);
    const io = io_mod.getIo();
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = follow });
    return encode(alloc, .{
        .ok = true,
        .type = kindName(stat.kind),
        .size = stat.size,
        .mode = stat.permissions.toMode(),
        .mtimeMs = stat.mtime.toMilliseconds(),
    });
}

fn fsRead(alloc: Allocator, args: std.json.ObjectMap) anyerror![]u8 {
    const path = stringArg(args, "path") orelse return invalidField(alloc, "path", "a string");
    const io = io_mod.getIo();
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const bytes = try io_mod.readFileToEnd(alloc, &file, max_file_bytes);
    defer alloc.free(bytes);
    const encoded = try encodeBase64(alloc, bytes);
    defer alloc.free(encoded);
    return encode(alloc, .{ .ok = true, .base64 = encoded });
}

fn fsWrite(alloc: Allocator, args: std.json.ObjectMap) anyerror![]u8 {
    const path = stringArg(args, "path") orelse return invalidField(alloc, "path", "a string");
    const decoded = try base64Arg(alloc, args);
    const bytes = switch (decoded) {
        .bytes => |bytes| bytes,
        .reply => |reply| return reply,
    };
    defer alloc.free(bytes);
    const append = boolArg(args, "append", false);
    const io = io_mod.getIo();
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = !append });
    defer file.close(io);
    const offset: u64 = if (append) (try file.stat(io)).size else 0;
    try file.writePositionalAll(io, bytes, offset);
    return encode(alloc, .{ .ok = true, .written = bytes.len });
}

fn fsReadRange(alloc: Allocator, args: std.json.ObjectMap) anyerror![]u8 {
    const path = stringArg(args, "path") orelse return invalidField(alloc, "path", "a string");
    const position = nonNegativeArg(args, "position") orelse return invalidField(alloc, "position", "a non-negative integer");
    const length = nonNegativeArg(args, "length") orelse return invalidField(alloc, "length", "a non-negative integer");
    if (length > max_file_bytes) return invalid(alloc, "length exceeds the read limit");
    const io = io_mod.getIo();
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const buffer = try alloc.alloc(u8, @intCast(length));
    defer alloc.free(buffer);
    const read = try file.readPositionalAll(io, buffer, position);
    const encoded = try encodeBase64(alloc, buffer[0..read]);
    defer alloc.free(encoded);
    return encode(alloc, .{ .ok = true, .base64 = encoded });
}

fn fsWriteAt(alloc: Allocator, args: std.json.ObjectMap) anyerror![]u8 {
    const path = stringArg(args, "path") orelse return invalidField(alloc, "path", "a string");
    const position_value = args.get("position") orelse std.json.Value.null;
    const position: ?u64 = switch (position_value) {
        .integer => |number| std.math.cast(u64, number) orelse return invalidField(alloc, "position", "a non-negative integer or null"),
        .null => null,
        else => return invalidField(alloc, "position", "a non-negative integer or null"),
    };
    const decoded = try base64Arg(alloc, args);
    const bytes = switch (decoded) {
        .bytes => |bytes| bytes,
        .reply => |reply| return reply,
    };
    defer alloc.free(bytes);
    const io = io_mod.getIo();
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = false });
    defer file.close(io);
    const offset = position orelse (try file.stat(io)).size;
    try file.writePositionalAll(io, bytes, offset);
    return encode(alloc, .{ .ok = true, .written = bytes.len, .position = offset });
}

fn fsReaddir(alloc: Allocator, args: std.json.ObjectMap) anyerror![]u8 {
    const path = stringArg(args, "path") orelse return invalidField(alloc, "path", "a string");
    const io = io_mod.getIo();
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"ok\":true,\"entries\":[");
    var iterator = dir.iterate();
    var first = true;
    while (try iterator.next(io)) |entry| {
        if (!first) try out.writer.writeByte(',');
        first = false;
        try out.writer.writeAll("{\"name\":");
        try std.json.Stringify.value(entry.name, .{}, &out.writer);
        try out.writer.print(",\"type\":\"{s}\"}}", .{kindName(entry.kind)});
    }
    try out.writer.writeAll("]}");
    return out.toOwnedSlice();
}

fn fsMkdir(alloc: Allocator, args: std.json.ObjectMap) anyerror![]u8 {
    const path = stringArg(args, "path") orelse return invalidField(alloc, "path", "a string");
    const io = io_mod.getIo();
    const cwd = std.Io.Dir.cwd();
    if (boolArg(args, "recursive", false)) {
        try cwd.createDirPath(io, path);
    } else {
        try cwd.createDir(io, path, .default_dir);
    }
    return encode(alloc, .{ .ok = true });
}

fn fsMkdtemp(alloc: Allocator, args: std.json.ObjectMap) anyerror![]u8 {
    const prefix = stringArg(args, "prefix") orelse return invalidField(alloc, "prefix", "a string");
    const io = io_mod.getIo();
    var random: [6]u8 = undefined;
    std.Io.random(io, &random);
    const suffix = std.fmt.bytesToHex(random, .lower);
    const path = try std.fmt.allocPrint(alloc, "{s}{s}", .{ prefix, suffix[0..] });
    defer alloc.free(path);
    try std.Io.Dir.cwd().createDir(io, path, .default_dir);
    return encode(alloc, .{ .ok = true, .path = path });
}

fn fsRemove(alloc: Allocator, args: std.json.ObjectMap) anyerror![]u8 {
    const path = stringArg(args, "path") orelse return invalidField(alloc, "path", "a string");
    const recursive = boolArg(args, "recursive", false);
    const force = boolArg(args, "force", false);
    const io = io_mod.getIo();
    const cwd = std.Io.Dir.cwd();
    const stat = cwd.statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => if (force) return encode(alloc, .{ .ok = true }) else return err,
        else => return err,
    };
    if (stat.kind == .directory) {
        if (!recursive) return encode(alloc, Failure{ .code = "EISDIR", .@"error" = "is a directory; pass recursive to remove it" });
        try cwd.deleteTree(io, path);
    } else {
        try cwd.deleteFile(io, path);
    }
    return encode(alloc, .{ .ok = true });
}

fn fsRename(alloc: Allocator, args: std.json.ObjectMap) anyerror![]u8 {
    const from = stringArg(args, "from") orelse return invalidField(alloc, "from", "a string");
    const to = stringArg(args, "to") orelse return invalidField(alloc, "to", "a string");
    const io = io_mod.getIo();
    const cwd = std.Io.Dir.cwd();
    try cwd.rename(from, cwd, to, io);
    return encode(alloc, .{ .ok = true });
}

fn fsCopy(alloc: Allocator, args: std.json.ObjectMap) anyerror![]u8 {
    const from = stringArg(args, "from") orelse return invalidField(alloc, "from", "a string");
    const to = stringArg(args, "to") orelse return invalidField(alloc, "to", "a string");
    const io = io_mod.getIo();
    const stat = try std.Io.Dir.cwd().statFile(io, from, .{});
    if (stat.kind == .directory) {
        if (!boolArg(args, "recursive", false)) return encode(alloc, Failure{ .code = "EISDIR", .@"error" = "is a directory; pass recursive to copy it" });
        try copyTree(alloc, from, to, 0);
    } else {
        try copyFile(alloc, from, to);
    }
    return encode(alloc, .{ .ok = true });
}

fn copyFile(alloc: Allocator, from: []const u8, to: []const u8) anyerror!void {
    const io = io_mod.getIo();
    const cwd = std.Io.Dir.cwd();
    var source = try cwd.openFile(io, from, .{});
    defer source.close(io);
    const bytes = try io_mod.readFileToEnd(alloc, &source, max_file_bytes);
    defer alloc.free(bytes);
    var target = try cwd.createFile(io, to, .{});
    defer target.close(io);
    try target.writePositionalAll(io, bytes, 0);
}

fn copyTree(alloc: Allocator, from: []const u8, to: []const u8, depth: usize) anyerror!void {
    if (depth > max_copy_depth) return error.NameTooLong;
    const io = io_mod.getIo();
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, to);
    var source = try cwd.openDir(io, from, .{ .iterate = true });
    defer source.close(io);
    var iterator = source.iterate();
    while (try iterator.next(io)) |entry| {
        const child_from = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ from, entry.name });
        defer alloc.free(child_from);
        const child_to = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ to, entry.name });
        defer alloc.free(child_to);
        if (entry.kind == .directory) {
            try copyTree(alloc, child_from, child_to, depth + 1);
        } else {
            try copyFile(alloc, child_from, child_to);
        }
    }
}

fn fsRealpath(alloc: Allocator, args: std.json.ObjectMap) anyerror![]u8 {
    const path = stringArg(args, "path") orelse return invalidField(alloc, "path", "a string");
    const real = try std.Io.Dir.cwd().realPathFileAlloc(io_mod.getIo(), path, alloc);
    defer alloc.free(real);
    return encode(alloc, .{ .ok = true, .path = real });
}

fn fsReadlink(alloc: Allocator, args: std.json.ObjectMap) anyerror![]u8 {
    const path = stringArg(args, "path") orelse return invalidField(alloc, "path", "a string");
    var buffer: [max_link_target_bytes]u8 = undefined;
    const length = try std.Io.Dir.cwd().readLink(io_mod.getIo(), path, &buffer);
    return encode(alloc, .{ .ok = true, .path = buffer[0..length] });
}

fn fsSymlink(alloc: Allocator, args: std.json.ObjectMap) anyerror![]u8 {
    const target = stringArg(args, "target") orelse return invalidField(alloc, "target", "a string");
    const path = stringArg(args, "path") orelse return invalidField(alloc, "path", "a string");
    try std.Io.Dir.cwd().symLink(io_mod.getIo(), target, path, .{});
    return encode(alloc, .{ .ok = true });
}

fn fsLink(alloc: Allocator, args: std.json.ObjectMap) anyerror![]u8 {
    const existing = stringArg(args, "existing") orelse return invalidField(alloc, "existing", "a string");
    const path = stringArg(args, "path") orelse return invalidField(alloc, "path", "a string");
    const cwd = std.Io.Dir.cwd();
    try cwd.hardLink(existing, cwd, path, io_mod.getIo(), .{});
    return encode(alloc, .{ .ok = true });
}

fn fsChmod(alloc: Allocator, args: std.json.ObjectMap) anyerror![]u8 {
    const path = stringArg(args, "path") orelse return invalidField(alloc, "path", "a string");
    const mode = nonNegativeArg(args, "mode") orelse return invalidField(alloc, "mode", "a non-negative integer");
    const io = io_mod.getIo();
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    try file.setPermissions(io, std.Io.File.Permissions.fromMode(@intCast(mode)));
    return encode(alloc, .{ .ok = true });
}

fn fsTruncate(alloc: Allocator, args: std.json.ObjectMap) anyerror![]u8 {
    const path = stringArg(args, "path") orelse return invalidField(alloc, "path", "a string");
    const length = nonNegativeArg(args, "length") orelse return invalidField(alloc, "length", "a non-negative integer");
    const io = io_mod.getIo();
    var file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
    defer file.close(io);
    try file.setLength(io, length);
    return encode(alloc, .{ .ok = true });
}

fn runCommand(alloc: Allocator, args: std.json.ObjectMap) anyerror![]u8 {
    const file = stringArg(args, "file") orelse return invalidField(alloc, "file", "a string");
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    try argv.append(alloc, file);
    if (args.get("args")) |value| {
        const items = switch (value) {
            .array => |array| array.items,
            else => return invalidField(alloc, "args", "an array of strings"),
        };
        for (items) |item| {
            switch (item) {
                .string => |text| try argv.append(alloc, text),
                else => return invalidField(alloc, "args", "an array of strings"),
            }
        }
    }
    if (stringArg(args, "input_base64")) |input| {
        if (input.len > 0) return invalid(alloc, "input_base64 is not supported by run_command in this build");
    }
    const io = io_mod.getIo();
    const cwd_option: std.process.Child.Cwd = if (stringArg(args, "cwd")) |dir| .{ .path = dir } else .inherit;
    var env_map = std.process.Environ.Map.init(alloc);
    defer env_map.deinit();
    if (args.get("env")) |value| {
        const object = switch (value) {
            .object => |object| object,
            else => return invalidField(alloc, "env", "an object of strings"),
        };
        var iterator = object.iterator();
        while (iterator.next()) |entry| {
            const text = switch (entry.value_ptr.*) {
                .string => |string| string,
                else => return invalidField(alloc, "env", "an object of strings"),
            };
            try env_map.put(entry.key_ptr.*, text);
        }
    } else {
        try env_map.put("PATH", "/usr/local/bin:/bin:/usr/bin");
    }
    const timeout: std.Io.Timeout = if (nonNegativeArg(args, "timeout_ms")) |ms|
        .{ .duration = .{ .raw = .fromMilliseconds(@intCast(ms)), .clock = .awake } }
    else
        .none;
    const result = try std.process.run(alloc, io, .{
        .argv = argv.items,
        .cwd = cwd_option,
        .environ_map = &env_map,
        .timeout = timeout,
        .stdout_limit = .limited(max_command_output_bytes),
        .stderr_limit = .limited(max_command_output_bytes),
    });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    const stdout_base64 = try encodeBase64(alloc, result.stdout);
    defer alloc.free(stdout_base64);
    const stderr_base64 = try encodeBase64(alloc, result.stderr);
    defer alloc.free(stderr_base64);
    const status: ?u8 = switch (result.term) {
        .exited => |code| code,
        else => null,
    };
    return encode(alloc, .{
        .ok = true,
        .status = status,
        .stdout_base64 = stdout_base64,
        .stderr_base64 = stderr_base64,
    });
}

fn randomBytes(alloc: Allocator, args: std.json.ObjectMap) anyerror![]u8 {
    const count = nonNegativeArg(args, "n") orelse return invalidField(alloc, "n", "a non-negative integer");
    if (count > max_random_bytes) return invalid(alloc, "n exceeds the random byte limit");
    const buffer = try alloc.alloc(u8, @intCast(count));
    defer alloc.free(buffer);
    std.Io.random(io_mod.getIo(), buffer);
    const encoded = try encodeBase64(alloc, buffer);
    defer alloc.free(encoded);
    return encode(alloc, .{ .ok = true, .base64 = encoded });
}

fn hashDigest(alloc: Allocator, args: std.json.ObjectMap) anyerror![]u8 {
    const algorithm = stringArg(args, "algorithm") orelse return invalidField(alloc, "algorithm", "a string");
    const decoded = try base64Arg(alloc, args);
    const bytes = switch (decoded) {
        .bytes => |bytes| bytes,
        .reply => |reply| return reply,
    };
    defer alloc.free(bytes);
    if (std.mem.eql(u8, algorithm, "sha1")) return digestReply(alloc, std.crypto.hash.Sha1, bytes);
    if (std.mem.eql(u8, algorithm, "sha256")) return digestReply(alloc, std.crypto.hash.sha2.Sha256, bytes);
    if (std.mem.eql(u8, algorithm, "sha512")) return digestReply(alloc, std.crypto.hash.sha2.Sha512, bytes);
    if (std.mem.eql(u8, algorithm, "md5")) return digestReply(alloc, std.crypto.hash.Md5, bytes);
    return invalidField(alloc, "algorithm", "sha1, sha256, sha512 or md5");
}

fn digestReply(alloc: std.mem.Allocator, comptime Hash: type, bytes: []const u8) ![]u8 {
    const hex = digestHex(Hash, bytes);
    return encode(alloc, .{ .ok = true, .hex = hex[0..] });
}

fn digestHex(comptime Hasher: type, bytes: []const u8) [Hasher.digest_length * 2]u8 {
    var digest: [Hasher.digest_length]u8 = undefined;
    Hasher.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

test "fs_write then fs_read round trip in a tmp dir" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/round.txt", .{tmp.sub_path[0..]});
    defer alloc.free(path);

    const write_args = try std.fmt.allocPrint(alloc, "{{\"path\":\"{s}\",\"base64\":\"aGVsbG8=\"}}", .{path});
    defer alloc.free(write_args);
    const written = try call(alloc, "fs_write", write_args);
    defer alloc.free(written);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"ok\":true") != null);

    const read_args = try std.fmt.allocPrint(alloc, "{{\"path\":\"{s}\"}}", .{path});
    defer alloc.free(read_args);
    const read = try call(alloc, "fs_read", read_args);
    defer alloc.free(read);
    try std.testing.expect(std.mem.indexOf(u8, read, "\"base64\":\"aGVsbG8=\"") != null);
}

test "fs_readdir lists entries with their kinds" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer alloc.free(dir_path);
    const entry_args = try std.fmt.allocPrint(alloc, "{{\"path\":\"{s}/entry.txt\",\"base64\":\"\"}}", .{dir_path});
    defer alloc.free(entry_args);
    const written = try call(alloc, "fs_write", entry_args);
    defer alloc.free(written);

    const list_args = try std.fmt.allocPrint(alloc, "{{\"path\":\"{s}\"}}", .{dir_path});
    defer alloc.free(list_args);
    const listing = try call(alloc, "fs_readdir", list_args);
    defer alloc.free(listing);
    try std.testing.expect(std.mem.indexOf(u8, listing, "\"entries\":[{\"name\":\"entry.txt\",\"type\":\"file\"}]") != null);
}

test "invalid arguments reply with EINVAL" {
    const alloc = std.testing.allocator;
    const not_json = try call(alloc, "fs_read", "not json");
    defer alloc.free(not_json);
    try std.testing.expect(std.mem.indexOf(u8, not_json, "\"ok\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, not_json, "\"code\":\"EINVAL\"") != null);

    const missing = try call(alloc, "fs_read", "{}");
    defer alloc.free(missing);
    try std.testing.expect(std.mem.indexOf(u8, missing, "\"code\":\"EINVAL\"") != null);
}

test "a host verb refuses an argument outside its schema by name" {
    const alloc = std.testing.allocator;
    const reply = try call(alloc, "fs_exists", "{\"path\":\".\",\"follow\":true}");
    defer alloc.free(reply);
    try std.testing.expect(std.mem.indexOf(u8, reply, "\"code\":\"EINVAL\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, reply, "fs_exists does not take argument \\\"follow\\\"; accepted fields: path") != null);
}
