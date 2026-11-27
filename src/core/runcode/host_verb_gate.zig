const std = @import("std");
const builtin = @import("builtin");
const host_verbs = @import("host_verbs.zig");
const message = @import("../shared/message.zig");
const tool_dispatch = @import("../tooling/tool_dispatch.zig");
const permission_gate = @import("../permissions/permission_gate.zig");
const command_admission = @import("../permissions/command_admission.zig");

pub const permission_denied_code = "EFX_PERMISSION_DENIED";

pub const Class = enum { read, write, execute, none, network };

pub const Row = struct {
    verb: []const u8,
    class: Class,
    path_keys: []const []const u8 = &.{},
};

pub const table = [_]Row{
    .{ .verb = "process_info", .class = .none },
    .{ .verb = "net_fetch", .class = .network },
    .{ .verb = "proc_spawn", .class = .execute },
    .{ .verb = "proc_write", .class = .none },
    .{ .verb = "proc_close_stdin", .class = .none },
    .{ .verb = "proc_read", .class = .none },
    .{ .verb = "proc_wait", .class = .none },
    .{ .verb = "proc_kill", .class = .none },
    .{ .verb = "dns_lookup", .class = .network },
    .{ .verb = "watch_start", .class = .read, .path_keys = &.{"path"} },
    .{ .verb = "watch_poll", .class = .none },
    .{ .verb = "watch_close", .class = .none },
    .{ .verb = "serve_listen", .class = .network },
    .{ .verb = "serve_accept", .class = .none },
    .{ .verb = "serve_respond", .class = .none },
    .{ .verb = "ws_send", .class = .none },
    .{ .verb = "ws_recv", .class = .none },
    .{ .verb = "pty_spawn", .class = .execute },
    .{ .verb = "pty_write", .class = .none },
    .{ .verb = "pty_read", .class = .none },
    .{ .verb = "pty_wait", .class = .none },
    .{ .verb = "sqlite_open", .class = .write, .path_keys = &.{"path"} },
    .{ .verb = "sqlite_exec", .class = .none },
    .{ .verb = "sqlite_all", .class = .none },
    .{ .verb = "sqlite_close", .class = .none },
    .{ .verb = "fs_exists", .class = .read, .path_keys = &.{"path"} },
    .{ .verb = "fs_stat", .class = .read, .path_keys = &.{"path"} },
    .{ .verb = "fs_read", .class = .read, .path_keys = &.{"path"} },
    .{ .verb = "fs_write", .class = .write, .path_keys = &.{"path"} },
    .{ .verb = "fs_read_range", .class = .read, .path_keys = &.{"path"} },
    .{ .verb = "fs_write_at", .class = .write, .path_keys = &.{"path"} },
    .{ .verb = "fs_readdir", .class = .read, .path_keys = &.{"path"} },
    .{ .verb = "fs_mkdir", .class = .write, .path_keys = &.{"path"} },
    .{ .verb = "fs_mkdtemp", .class = .write, .path_keys = &.{"prefix"} },
    .{ .verb = "fs_remove", .class = .write, .path_keys = &.{"path"} },
    .{ .verb = "fs_rename", .class = .write, .path_keys = &.{ "from", "to" } },
    .{ .verb = "fs_copy", .class = .write, .path_keys = &.{ "from", "to" } },
    .{ .verb = "fs_realpath", .class = .read, .path_keys = &.{"path"} },
    .{ .verb = "fs_readlink", .class = .read, .path_keys = &.{"path"} },
    .{ .verb = "fs_symlink", .class = .write, .path_keys = &.{"path"} },
    .{ .verb = "fs_link", .class = .write, .path_keys = &.{ "path", "existing" } },
    .{ .verb = "fs_chmod", .class = .write, .path_keys = &.{"path"} },
    .{ .verb = "fs_truncate", .class = .write, .path_keys = &.{"path"} },
    .{ .verb = "run_command", .class = .execute },
    .{ .verb = "random_bytes", .class = .none },
    .{ .verb = "hash_digest", .class = .none },
};

comptime {
    @setEvalBranchQuota(20000);
    if (table.len != host_verbs.names.len) @compileError("every host verb needs exactly one permission row");
    for (host_verbs.names) |name| {
        var rows: usize = 0;
        for (table) |row| {
            if (std.mem.eql(u8, row.verb, name)) rows += 1;
        }
        if (rows != 1) @compileError("host verb " ++ name ++ " needs exactly one permission row");
    }
}

pub fn rowFor(verb: []const u8) ?Row {
    for (table) |row| {
        if (std.mem.eql(u8, row.verb, verb)) return row;
    }
    return null;
}

pub fn toolNameFor(class: Class) ?[]const u8 {
    return switch (class) {
        .read => "read_file",
        .write => "write_file",
        .execute => "Bash",
        .network => "FetchURL",
        .none => null,
    };
}

pub fn refusal(
    ctx: tool_dispatch.DispatchContext,
    registry: tool_dispatch.Registry,
    reply_alloc: std.mem.Allocator,
    verb: []const u8,
    args_json: []const u8,
) !?[]u8 {
    const row = rowFor(verb) orelse return try denialReply(reply_alloc, verb, "host verb has no permission row");
    if (row.class == .none) return null;
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const args = parsed.value.object;
    if (row.class == .execute) {
        const command = try shellCommand(ctx.allocator, args);
        const call_json = try encodeJson(ctx.allocator, .{ .command = command });
        return try admit(ctx, registry, reply_alloc, verb, toolNameFor(row.class).?, call_json);
    }
    if (row.class == .network) {
        const url = switch (args.get("url") orelse return null) {
            .string => |text| text,
            else => return null,
        };
        const loopback = switch (args.get("loopback") orelse .null) {
            .bool => |flag| flag,
            else => false,
        };
        var fetch_ctx = ctx;
        fetch_ctx.host_fetch_loopback = loopback;
        const call_json = try encodeJson(ctx.allocator, .{ .url = url });
        return try admit(fetch_ctx, registry, reply_alloc, verb, "FetchURL", call_json);
    }
    const tool_name = toolNameFor(row.class).?;
    for (row.path_keys) |key| {
        const path = switch (args.get(key) orelse continue) {
            .string => |text| text,
            else => continue,
        };
        const call_json = if (row.class == .read)
            try encodeJson(ctx.allocator, .{ .path = path })
        else
            try encodeJson(ctx.allocator, .{ .path = path, .content = "" });
        if (try admit(ctx, registry, reply_alloc, verb, tool_name, call_json)) |reply| return reply;
    }
    return null;
}

fn admit(
    ctx: tool_dispatch.DispatchContext,
    registry: tool_dispatch.Registry,
    reply_alloc: std.mem.Allocator,
    verb: []const u8,
    tool_name: []const u8,
    call_json: []const u8,
) !?[]u8 {
    const call: message.ToolCall = .{ .id = if (ctx.tool_call_id.len == 0) "host_verb" else ctx.tool_call_id, .name = tool_name, .arguments_json = call_json };
    if (ctx.inner_call_gate) |gate| {
        if (try gate.authorize_fn(gate.context, ctx.allocator, call)) |denied| return try denialReply(reply_alloc, verb, denied);
        switch (try gate.start_fn(gate.context, ctx.allocator, call)) {
            .refuse => |text| return try denialReply(reply_alloc, verb, text),
            else => {},
        }
        return null;
    }
    switch (try tool_dispatch.admitToolCall(ctx, registry, call)) {
        .admitted => |admitted| {
            admitted.deinit();
            return null;
        },
        .not_registered => return try denialReply(reply_alloc, verb, "the equivalent model tool is not registered"),
        .failure => |body| return try denialReply(reply_alloc, verb, body),
    }
}

fn shellCommand(alloc: std.mem.Allocator, args: std.json.ObjectMap) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    const file = switch (args.get("file") orelse return try alloc.dupe(u8, "")) {
        .string => |text| text,
        else => return try alloc.dupe(u8, ""),
    };
    try out.writer.writeAll(file);
    if (args.get("args")) |value| {
        if (value == .array) {
            for (value.array.items) |item| {
                if (item != .string) continue;
                try out.writer.writeAll(" '");
                for (item.string) |byte| {
                    if (byte == '\'') try out.writer.writeAll("'\\''") else try out.writer.writeByte(byte);
                }
                try out.writer.writeByte('\'');
            }
        }
    }
    return out.toOwnedSlice();
}

fn encodeJson(alloc: std.mem.Allocator, value: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}

fn denialReply(alloc: std.mem.Allocator, verb: []const u8, detail: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"ok\":false,\"code\":");
    try std.json.Stringify.value(permission_denied_code, .{}, &out.writer);
    try out.writer.writeAll(",\"verb\":");
    try std.json.Stringify.value(verb, .{}, &out.writer);
    try out.writer.writeAll(",\"error\":");
    try std.json.Stringify.value(detail, .{}, &out.writer);
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

var test_command_token: u8 = 0;

fn allowCommandOutcome(
    context: *anyopaque,
    arena: std.mem.Allocator,
    tool_call: message.ToolCall,
    permission_mode: permission_gate.PermissionMode,
) anyerror!command_admission.PermissionOutcome {
    _ = context;
    _ = arena;
    _ = permission_mode;
    return .{
        .decision = .once,
        .execution_authority = .{ .run_command = .{ .shell_allowed = .{
            .fingerprint = .{ .command = tool_call.arguments_json, .resolved_cwd = ".", .target_os = builtin.os.tag },
            .source = .js_host,
        } } },
    };
}

fn testContext(arena: std.mem.Allocator, mode: permission_gate.PermissionMode) tool_dispatch.DispatchContext {
    return .{
        .allocator = arena,
        .workspace_root = ".",
        .permission_mode = mode,
        .command_outcome = .{ .context = &test_command_token, .outcome = allowCommandOutcome },
    };
}

fn sampleArgs(verb: []const u8) []const u8 {
    if (std.mem.eql(u8, verb, "run_command")) return "{\"file\":\"true\"}";
    if (std.mem.eql(u8, verb, "fs_mkdtemp")) return "{\"prefix\":\"gate-\"}";
    if (std.mem.eql(u8, verb, "fs_rename") or std.mem.eql(u8, verb, "fs_copy")) return "{\"from\":\"a.txt\",\"to\":\"b.txt\"}";
    if (std.mem.eql(u8, verb, "fs_link")) return "{\"path\":\"a.txt\",\"existing\":\"b.txt\"}";
    return "{\"path\":\"a.txt\"}";
}

test "every host verb has exactly one permission row" {
    try std.testing.expectEqual(host_verbs.names.len, table.len);
    for (host_verbs.names) |name| {
        var rows: usize = 0;
        for (table) |row| {
            if (std.mem.eql(u8, row.verb, name)) rows += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), rows);
    }
}

test "ask mode refuses write and execute rows and admits read and none rows" {
    const builtin_tools = @import("../../builtins/tools.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx = testContext(arena.allocator(), .ask);
    for (table) |row| {
        const reply = try refusal(ctx, builtin_tools.registry_with_tower, arena.allocator(), row.verb, sampleArgs(row.verb));
        switch (row.class) {
            .read, .none => try std.testing.expect(reply == null),
            .write, .execute => {
                try std.testing.expect(reply != null);
                try std.testing.expect(std.mem.indexOf(u8, reply.?, permission_denied_code) != null);
            },
        }
    }
}

test "yolo mode admits every row" {
    const builtin_tools = @import("../../builtins/tools.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx = testContext(arena.allocator(), .yolo);
    for (table) |row| {
        const reply = try refusal(ctx, builtin_tools.registry_with_tower, arena.allocator(), row.verb, sampleArgs(row.verb));
        try std.testing.expect(reply == null);
    }
}

test "none rows are admitted in every permission mode" {
    const builtin_tools = @import("../../builtins/tools.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    inline for (.{ .ask, .auto, .yolo, .dontAsk }) |mode| {
        const ctx = testContext(arena.allocator(), mode);
        for (table) |row| {
            if (row.class != .none) continue;
            try std.testing.expect((try refusal(ctx, builtin_tools.registry_with_tower, arena.allocator(), row.verb, "{}")) == null);
        }
    }
}
