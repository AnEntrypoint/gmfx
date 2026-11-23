const std = @import("std");
const builtin = @import("builtin");
const text_utils = @import("../shared/text_utils.zig");
const tool_args = @import("tool_args.zig");
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

pub fn calledVerbs(arena: Allocator, call: ToolCall, output: []const u8) Allocator.Error!?[]const u8 {
    if (!isRunCode(call.name)) return null;
    const report = try parseReport(arena, output) orelse return null;
    var out: std.ArrayList(u8) = .empty;
    for (report.calls, 0..) |inner, index| {
        if (calledBefore(report.calls[0..index], inner.verb)) continue;
        if (out.items.len > 0) try out.appendSlice(arena, ", ");
        try out.appendSlice(arena, inner.verb);
    }
    return if (out.items.len > 0) out.items else null;
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

fn calledBefore(earlier: []const InnerCall, verb: []const u8) bool {
    for (earlier) |inner| if (std.mem.eql(u8, inner.verb, verb)) return true;
    return false;
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
    try std.testing.expectEqualStrings("read_file, fs_stat", (try calledVerbs(arena, test_call, test_output)).?);
    try std.testing.expect(try calledVerbs(arena, test_call, "not json") == null);
    try std.testing.expect(try calledVerbs(arena, .{ .id = "r", .name = "read_file", .arguments_json = "{}" }, test_output) == null);
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
