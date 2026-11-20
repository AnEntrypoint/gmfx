const std = @import("std");
const builtin_tools = @import("../builtins/tools.zig");
const jsonrpc = @import("../acp/jsonrpc.zig");
const model_tool_schema = @import("../core/tooling/model_tool_schema.zig");
const tool_dispatch = @import("../core/tooling/tool_dispatch.zig");
const status = @import("status.zig");
const wire = @import("wire.zig");

const Allocator = std.mem.Allocator;

const exposed = [_]tool_dispatch.Tool{
    builtin_tools.read_file,
    builtin_tools.glob_files,
    builtin_tools.grep_files,
};

fn exposedTool(name: []const u8) bool {
    for (exposed) |tool| {
        if (std.mem.eql(u8, tool.name, name)) return true;
    }
    return false;
}

pub fn writeList(alloc: Allocator, w: *std.Io.Writer, modern: bool) !void {
    try w.writeByte('{');
    try wire.writeCacheable(w, modern);
    try w.writeAll("\"tools\":[");
    for (exposed, 0..) |tool, index| {
        if (index > 0) try w.writeByte(',');
        try w.writeAll("{\"name\":");
        try jsonrpc.writeJsonStr(tool.name, w);
        try w.writeAll(",\"description\":");
        try jsonrpc.writeJsonStr(tool.description, w);
        try w.writeAll(",\"inputSchema\":");
        try model_tool_schema.writeObjectSchema(alloc, w, tool.model_schema.input_schema);
        try w.writeByte('}');
    }
    for (status.tools) |tool| {
        try w.writeByte(',');
        try w.writeAll("{\"name\":");
        try jsonrpc.writeJsonStr(tool.name, w);
        try w.writeAll(",\"description\":");
        try jsonrpc.writeJsonStr(tool.description, w);
        try w.writeAll(",\"inputSchema\":{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}}");
    }
    try w.writeAll("]}");
}

pub fn call(alloc: Allocator, workspace_root: []const u8, runs_root: ?std.Io.Dir, params: std.json.Value, w: *std.Io.Writer, modern: bool) !void {
    if (params != .object) return error.InvalidParams;
    const name_value = params.object.get("name") orelse return error.InvalidParams;
    if (name_value != .string) return error.InvalidParams;
    const name = name_value.string;
    if (status.isTool(name)) return callStatus(alloc, runs_root, name, w, modern);
    if (!exposedTool(name)) return error.UnknownTool;
    const arguments_json = try argumentsJson(alloc, params.object.get("arguments"));
    const ctx = tool_dispatch.DispatchContext{
        .allocator = alloc,
        .workspace_root = workspace_root,
    };
    const registry = tool_dispatch.Registry{ .tools = &exposed };
    const result = tool_dispatch.dispatchToolCall(ctx, registry, .{
        .id = "mcp",
        .name = name,
        .arguments_json = arguments_json,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return writeContent(w, @errorName(err), true, modern),
    };
    try writeContent(w, result.body, result.status != .success, modern);
}

fn callStatus(alloc: Allocator, runs_root: ?std.Io.Dir, name: []const u8, w: *std.Io.Writer, modern: bool) !void {
    var out: std.Io.Writer.Allocating = .init(alloc);
    try status.write(alloc, runs_root, name, &out.writer);
    try writeContent(w, out.written(), false, modern);
}

fn argumentsJson(alloc: Allocator, arguments: ?std.json.Value) ![]const u8 {
    const value = arguments orelse return try alloc.dupe(u8, "{}");
    var out: std.Io.Writer.Allocating = .init(alloc);
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.written();
}

fn writeContent(w: *std.Io.Writer, text: []const u8, is_error: bool, modern: bool) !void {
    try w.writeByte('{');
    try wire.writeComplete(w, modern);
    try w.writeAll("\"content\":[{\"type\":\"text\",\"text\":");
    try jsonrpc.writeJsonStr(text, w);
    try w.writeAll("}],\"isError\":");
    try w.writeAll(if (is_error) "true}" else "false}");
}
