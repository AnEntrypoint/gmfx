const std = @import("std");
const builtin = @import("builtin");
const text_utils = @import("../shared/text_utils.zig");
const tool_args = @import("tool_args.zig");
const file_mutation_contract = @import("file_mutation_contract.zig");
const tool_dispatch = @import("tool_dispatch.zig");
const types = @import("../shared/types.zig");
const test_builtin_tools = if (builtin.is_test)
    @import("../../builtins/tools.zig")
else
    struct {};

const Allocator = std.mem.Allocator;
const ToolCall = types.ToolCall;

pub const tool_name = "run_code";
const max_title_bytes = 80;
const max_error_bytes = 200;

const InnerCall = struct {
    verb: []const u8,
    args: []const u8 = "",
    ok: bool = false,
    notice: ?[]const u8 = null,
    additions: ?u32 = null,
    deletions: ?u32 = null,
};

pub const Row = struct {
    call: ToolCall,
    ok: bool,
    target: ?[]const u8,
    additions: usize,
    deletions: usize,
};

const Report = struct {
    @"error": ?[]const u8 = null,
    calls: []const InnerCall = &.{},
    calls_dropped: usize = 0,
};

pub fn isRunCode(name: []const u8) bool {
    return std.mem.eql(u8, name, tool_name);
}

fn parseReport(arena: Allocator, output: []const u8) Allocator.Error!?Report {
    return std.json.parseFromSliceLeaky(Report, arena, output, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
}

fn body(arena: Allocator, call: ToolCall) Allocator.Error![]const u8 {
    const args = tool_args.parseToolArgsObject(arena, call.arguments_json) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return "",
    };
    const value = args.get("body") orelse return "";
    return if (value == .string) value.string else "";
}

pub fn firstBodyLine(arena: Allocator, call: ToolCall) Allocator.Error![]const u8 {
    const text = std.mem.trim(u8, try body(arena, call), " \t\r\n");
    const line = text[0 .. std.mem.findScalar(u8, text, '\n') orelse text.len];
    return text_utils.utf8PrefixByBytes(std.mem.trimEnd(u8, line, " \t\r"), max_title_bytes);
}

pub fn title(arena: Allocator, call: ToolCall) Allocator.Error![]const u8 {
    return arena.print("{s} {s}", .{ tool_name, try firstBodyLine(arena, call) });
}

pub fn rows(arena: Allocator, call: ToolCall, output: []const u8) Allocator.Error![]const Row {
    if (!isRunCode(call.name)) return &.{};
    const report = try parseReport(arena, output) orelse return &.{};
    const out = try arena.alloc(Row, report.calls.len);
    for (report.calls, out, 1..) |inner, *row, number| row.* = .{
        .call = .{ .id = try arena.print("{s}:{d}", .{ call.id, number }), .name = inner.verb, .arguments_json = inner.args },
        .ok = inner.ok,
        .target = try mutationTarget(arena, inner),
        .additions = inner.additions orelse 0,
        .deletions = inner.deletions orelse 0,
    };
    return out;
}

fn mutationTarget(arena: Allocator, inner: InnerCall) Allocator.Error!?[]const u8 {
    if (!file_mutation_contract.isToolName(inner.verb)) return null;
    const args = tool_args.parseToolArgsObject(arena, inner.args) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    const path = args.get("path") orelse return null;
    return if (path == .string) path.string else null;
}

pub fn changedFiles(call: ToolCall, output: []const u8, registry: tool_dispatch.Registry, arena: Allocator) Allocator.Error!bool {
    if (!isRunCode(call.name)) return false;
    const report = try parseReport(arena, output) orelse return false;
    for (report.calls) |inner| {
        if (!inner.ok) continue;
        const tool = registry.lookup(inner.verb) orelse continue;
        if (tool.activity_kind == .write or tool.activity_kind == .edit) return true;
    }
    return false;
}

pub fn leadingCall(arena: Allocator, registry: tool_dispatch.Registry, call: ToolCall) Allocator.Error!?ToolCall {
    if (!isRunCode(call.name)) return null;
    var rest = try body(arena, call);
    while (std.mem.find(u8, rest, "gm.")) |at| {
        rest = rest[at + "gm.".len ..];
        var end: usize = 0;
        while (end < rest.len and (std.ascii.isAlphanumeric(rest[end]) or rest[end] == '_')) end += 1;
        if (registry.lookup(rest[0..end]) != null) return .{ .id = call.id, .name = rest[0..end], .arguments_json = "{}" };
    }
    return null;
}

fn argsSummary(arena: Allocator, registry: tool_dispatch.Registry, inner: InnerCall) Allocator.Error![]const u8 {
    const tool = registry.lookup(inner.verb) orelse return inner.args;
    const args = tool_args.parseToolArgsObject(arena, inner.args) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return inner.args,
    };
    return tool_dispatch.presentationLabelValue(tool_dispatch.presentationForArgs(tool.*, args), args) orelse inner.args;
}

pub fn bodyBlock(alloc: Allocator, call: ToolCall) Allocator.Error!?[]u8 {
    if (!isRunCode(call.name)) return null;
    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer scratch_state.deinit();
    return try alloc.dupe(u8, try codeFence(scratch_state.allocator(), try body(scratch_state.allocator(), call)));
}

fn codeFence(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    return arena.print("```js\n{s}\n```", .{text});
}

pub fn detail(alloc: Allocator, registry: tool_dispatch.Registry, call: ToolCall, output: []const u8) Allocator.Error!?[]u8 {
    if (!isRunCode(call.name)) return null;
    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    const report = try parseReport(scratch, output) orelse return null;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (report.calls) |inner| {
        try out.print(alloc, "  {s}({s}) -> {s}\n", .{ inner.verb, try argsSummary(scratch, registry, inner), if (inner.ok) "ok" else "error" });
        if (inner.notice) |notice| try out.print(alloc, "    notice: {s}\n", .{notice});
    }
    if (report.calls_dropped > 0) try out.print(alloc, "  ... {d} more calls\n", .{report.calls_dropped});
    if (report.@"error") |message| try out.print(alloc, "error: {s}\n", .{text_utils.utf8PrefixByBytes(message, max_error_bytes)});
    try out.appendSlice(alloc, try codeFence(scratch, try body(scratch, call)));
    return try out.toOwnedSlice(alloc);
}

pub const test_call: ToolCall = .{
    .id = "rc",
    .name = tool_name,
    .arguments_json = "{\"body\":\"  const a = await gm.read_file({path:'a.txt'});\\nreturn 3;\"}",
};

pub const test_output =
    "{\"ok\":true,\"value\":3,\"console\":\"\",\"console_dropped\":0,\"calls\":[" ++
    "{\"verb\":\"read_file\",\"args\":\"{\\\"path\\\":\\\"a.txt\\\"}\",\"ok\":true}," ++
    "{\"verb\":\"fs_stat\",\"args\":\"{\\\"path\\\":\\\"b\\\"}\",\"ok\":false}," ++
    "{\"verb\":\"read_file\",\"args\":\"{\\\"path\\\":\\\"c.txt\\\"}\",\"ok\":true}],\"calls_dropped\":0}";

pub const test_detail =
    "  read_file(a.txt) -> ok\n" ++
    "  fs_stat({\"path\":\"b\"}) -> error\n" ++
    "  read_file(c.txt) -> ok\n" ++
    "```js\n  const a = await gm.read_file({path:'a.txt'});\nreturn 3;\n```";

test "run_code presents its body line before results and the verbs it called after" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("run_code const a = await gm.read_file({path:'a.txt'});", try title(arena, test_call));
}

test "run_code rows give each inner call its own call, target and diff counts in ledger order" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const output = "{\"ok\":true,\"calls\":[" ++
        "{\"verb\":\"write_file\",\"args\":\"{\\\"path\\\":\\\"a.txt\\\"}\",\"ok\":true,\"additions\":3,\"deletions\":1}," ++
        "{\"verb\":\"read_file\",\"args\":\"{\\\"path\\\":\\\"b.txt\\\"}\",\"ok\":false}],\"calls_dropped\":0}";
    const shown = try rows(arena, test_call, output);
    try std.testing.expectEqual(@as(usize, 2), shown.len);
    try std.testing.expectEqualStrings("rc:1", shown[0].call.id);
    try std.testing.expectEqualStrings("write_file", shown[0].call.name);
    try std.testing.expectEqualStrings("a.txt", shown[0].target.?);
    try std.testing.expect(shown[0].ok);
    try std.testing.expectEqual(@as(usize, 3), shown[0].additions);
    try std.testing.expectEqual(@as(usize, 1), shown[0].deletions);
    try std.testing.expectEqualStrings("rc:2", shown[1].call.id);
    try std.testing.expect(shown[1].target == null);
    try std.testing.expect(!shown[1].ok);
    try std.testing.expectEqual(@as(usize, 0), (try rows(arena, test_call, "not json")).len);
    try std.testing.expectEqual(@as(usize, 0), (try rows(arena, .{ .id = "r", .name = "read_file", .arguments_json = "{}" }, output)).len);
}

test "run_code leading call names the first registered verb the body calls" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("read_file", (try leadingCall(arena, test_builtin_tools.registry, test_call)).?.name);
    const writing: ToolCall = .{ .id = "w", .name = tool_name, .arguments_json = "{\"body\":\"const v = await gm.verbs({names:true});\\nawait gm.write_file({path:'x'});\"}" };
    const leading = (try leadingCall(arena, test_builtin_tools.registry, writing)).?;
    try std.testing.expectEqualStrings("write_file", leading.name);
    try std.testing.expectEqualStrings("w", leading.id);
    const plain: ToolCall = .{ .id = "p", .name = tool_name, .arguments_json = "{\"body\":\"return 1;\"}" };
    try std.testing.expect(try leadingCall(arena, test_builtin_tools.registry, plain) == null);
    try std.testing.expect(try leadingCall(arena, test_builtin_tools.registry, .{ .id = "r", .name = "read_file", .arguments_json = "{}" }) == null);
}

test "run_code reports changed files only for a successful inner write or edit" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const registry = test_builtin_tools.registry;
    const wrote = "{\"ok\":true,\"calls\":[{\"verb\":\"write_file\",\"args\":\"{}\",\"ok\":true}],\"calls_dropped\":0}";
    const failed_write = "{\"ok\":false,\"calls\":[{\"verb\":\"write_file\",\"args\":\"{}\",\"ok\":false}],\"calls_dropped\":0}";
    try std.testing.expect(try changedFiles(test_call, wrote, registry, arena));
    try std.testing.expect(!try changedFiles(test_call, failed_write, registry, arena));
    try std.testing.expect(!try changedFiles(test_call, test_output, registry, arena));
    try std.testing.expect(!try changedFiles(.{ .id = "r", .name = "write_file", .arguments_json = "{}" }, wrote, registry, arena));
}

test "run_code detail shows the notice an inner call carried under that call" {
    const output = "{\"ok\":true,\"calls\":[{\"verb\":\"read_file\",\"args\":\"{}\",\"ok\":true,\"notice\":\"shell snapshot unavailable\"}],\"calls_dropped\":0}";
    const text = (try detail(std.testing.allocator, test_builtin_tools.registry, test_call, output)).?;
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.find(u8, text, "-> ok\n    notice: shell snapshot unavailable\n") != null);
}

test "run_code detail lists each inner call with its own presenter's summary and the body as JavaScript" {
    const text = (try detail(std.testing.allocator, test_builtin_tools.registry, test_call, test_output)).?;
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(test_detail, text);
    const failed = (try detail(std.testing.allocator, test_builtin_tools.registry, test_call, "{\"ok\":false,\"error\":\"boom\",\"calls\":[],\"calls_dropped\":2}")).?;
    defer std.testing.allocator.free(failed);
    try std.testing.expectEqualStrings("  ... 2 more calls\nerror: boom\n```js\n  const a = await gm.read_file({path:'a.txt'});\nreturn 3;\n```", failed);
    try std.testing.expect(try detail(std.testing.allocator, test_builtin_tools.registry, .{ .id = "r", .name = "read_file", .arguments_json = "{}" }, test_output) == null);
}
