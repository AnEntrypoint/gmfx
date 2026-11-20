const std = @import("std");
const model_context_encoding = @import("../shared/model_context_encoding.zig");
const tool_dispatch = @import("tool_dispatch.zig");
const tool_result_errors = @import("tool_result_errors.zig");

const Allocator = std.mem.Allocator;

const invalid_arguments_message = "Invalid select_tools arguments.";
const names_required_message = "select_tools requires one or more exact dynamic tool names.";

const SelectInput = struct {
    names: [][]u8,

    fn deinit(self: *SelectInput, alloc: Allocator) void {
        for (self.names) |name| alloc.free(name);
        alloc.free(self.names);
        self.* = .{ .names = &.{} };
    }
};

pub fn decodeSelect(
    ctx: tool_dispatch.DispatchContext,
    args_json: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, invalid_arguments_message) };
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return .{ .failure = try ctx.allocator.dupe(u8, invalid_arguments_message) };
    }
    const names_value = parsed.value.object.get("names") orelse {
        return .{ .failure = try ctx.allocator.dupe(u8, names_required_message) };
    };
    if (names_value != .array or names_value.array.items.len == 0) {
        return .{ .failure = try ctx.allocator.dupe(u8, names_required_message) };
    }
    for (names_value.array.items) |item| {
        if (item != .string or item.string.len == 0) {
            return .{ .failure = try ctx.allocator.dupe(u8, names_required_message) };
        }
    }

    const names = try ctx.allocator.alloc([]u8, names_value.array.items.len);
    var filled: usize = 0;
    errdefer {
        for (names[0..filled]) |name| ctx.allocator.free(name);
        ctx.allocator.free(names);
    }
    for (names_value.array.items, names) |item, *slot| {
        slot.* = try ctx.allocator.dupe(u8, item.string);
        filled += 1;
    }
    const input = try ctx.allocator.create(SelectInput);
    errdefer ctx.allocator.destroy(input);
    input.* = .{ .names = names };
    return .{ .input = .{ .ptr = input, .deinit_fn = selectInputDeinit } };
}

pub fn validate(
    _: tool_dispatch.DispatchContext,
    _: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!?[]u8 {
    return null;
}

pub fn callSelect(
    ctx: tool_dispatch.DispatchContext,
    erased: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(SelectInput);
    var report: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer report.deinit();
    var selected_count: usize = 0;
    for (input.names, 0..) |name, index| {
        if (index > 0) report.writer.writeByte('\n') catch return error.OutOfMemory;
        if (try selectOne(ctx, name, &report.writer)) selected_count += 1;
    }
    const text = report.toOwnedSlice() catch return error.OutOfMemory;
    if (selected_count == 0) return .{ .failure = text };
    return .{ .success = text };
}

fn selectOne(
    ctx: tool_dispatch.DispatchContext,
    name: []const u8,
    out: *std.Io.Writer,
) tool_dispatch.DispatchError!bool {
    const runtime_context = ctx.mcp_ctx orelse return writeFailure(out, "No MCP runtime is available.");
    const tool_schema = ctx.mcp_tool_schema orelse return writeFailure(out, "No MCP runtime is available.");
    const schema_result = (tool_schema(
        runtime_context,
        ctx.allocator,
        name,
        ctx.mcp_permission_rules,
        ctx.context_limits,
        ctx.mcp_access,
        ctx.cancel_flag,
    ) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (err == error.Cancelled) return error.Cancelled;
        const message = try tool_result_errors.formatToolExecutionErrorJson(
            ctx.allocator,
            "select_tools",
            err,
        );
        defer ctx.allocator.free(message);
        return writeFailure(out, message);
    }) orelse {
        out.print("Dynamic MCP tool not found or not allowed: {s}", .{name}) catch return error.OutOfMemory;
        return false;
    };
    switch (schema_result) {
        .rejected => |payload| {
            defer ctx.allocator.free(payload.model_output);
            if (payload.notice) |notice| {
                defer ctx.allocator.free(notice);
                try tool_dispatch.reportContextNotice(ctx, notice);
            }
            return writeFailure(out, payload.model_output);
        },
        .selected => |payload| {
            defer ctx.allocator.free(payload.model_output);
            defer if (payload.notice) |notice| ctx.allocator.free(notice);
            if (payload.notice) |notice| try tool_dispatch.reportContextNotice(ctx, notice);
            try tool_dispatch.reportSelectedDynamicTool(ctx, name, payload.model_output, payload.mcp_binding);
        },
    }
    out.writeAll("Selected dynamic MCP tool `") catch return error.OutOfMemory;
    model_context_encoding.writeScalar(out, name) catch return error.OutOfMemory;
    out.writeAll("`. Its executable schema will be available on the next model step; call `") catch return error.OutOfMemory;
    model_context_encoding.writeScalar(out, name) catch return error.OutOfMemory;
    out.writeAll("` with arguments matching the selected schema.") catch return error.OutOfMemory;
    return true;
}

fn writeFailure(out: *std.Io.Writer, message: []const u8) tool_dispatch.DispatchError!bool {
    out.writeAll(message) catch return error.OutOfMemory;
    return false;
}

const read_resource_tool_name = "ReadMcpResourceTool";
const read_resource_invalid_message = "Invalid ReadMcpResourceTool arguments.";
const read_resource_required_message = "ReadMcpResourceTool requires an MCP server name and a resource uri.";
const mcp_unavailable_message = "MCP is not available in this session.";

const ReadResourceInput = struct {
    server: []u8,
    uri: []u8,

    fn deinit(self: *ReadResourceInput, alloc: Allocator) void {
        alloc.free(self.server);
        alloc.free(self.uri);
        self.* = .{ .server = &.{}, .uri = &.{} };
    }
};

pub fn decodeReadResource(
    ctx: tool_dispatch.DispatchContext,
    args_json: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, read_resource_invalid_message) };
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return .{ .failure = try ctx.allocator.dupe(u8, read_resource_invalid_message) };
    }
    const server = nonEmptyStringField(parsed.value.object, "server") orelse {
        return .{ .failure = try ctx.allocator.dupe(u8, read_resource_required_message) };
    };
    const uri = nonEmptyStringField(parsed.value.object, "uri") orelse {
        return .{ .failure = try ctx.allocator.dupe(u8, read_resource_required_message) };
    };

    const input = try ctx.allocator.create(ReadResourceInput);
    errdefer ctx.allocator.destroy(input);
    const server_copy = try ctx.allocator.dupe(u8, server);
    errdefer ctx.allocator.free(server_copy);
    const uri_copy = try ctx.allocator.dupe(u8, uri);
    errdefer ctx.allocator.free(uri_copy);
    input.* = .{ .server = server_copy, .uri = uri_copy };
    return .{ .input = .{ .ptr = input, .deinit_fn = readResourceInputDeinit } };
}

fn nonEmptyStringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string or value.string.len == 0) return null;
    return value.string;
}

pub fn callReadResource(
    ctx: tool_dispatch.DispatchContext,
    erased: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(ReadResourceInput);
    const runtime_context = ctx.mcp_ctx orelse return .{ .failure = try ctx.allocator.dupe(u8, mcp_unavailable_message) };
    const read_resource = ctx.mcp_read_resource orelse return .{ .failure = try ctx.allocator.dupe(u8, mcp_unavailable_message) };
    const answer = read_resource(
        runtime_context,
        ctx.allocator,
        input.server,
        .{ .read = input.uri },
        ctx.mcp_access,
        ctx.cancel_flag,
    ) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (err == error.Cancelled) return error.Cancelled;
        return .{ .failure = try tool_result_errors.formatToolExecutionErrorJson(ctx.allocator, read_resource_tool_name, err) };
    };
    return switch (answer) {
        .result => |raw| .{ .success = try resourceText(ctx.allocator, raw) },
        .failure => |failure| .{ .failure = try ctx.allocator.dupe(u8, failure.message) },
        .ended => |reason| .{ .failure = try std.fmt.allocPrint(ctx.allocator, "The MCP server ended the request: {s}.", .{reason}) },
        .unknown_server => .{ .failure = try std.fmt.allocPrint(ctx.allocator, "No MCP server named {s} is configured.", .{input.server}) },
    };
}

fn resourceText(alloc: Allocator, raw: []const u8) tool_dispatch.DispatchError![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, raw, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return alloc.dupe(u8, raw),
    };
    defer parsed.deinit();
    if (parsed.value != .object) return alloc.dupe(u8, raw);
    const contents = parsed.value.object.get("contents") orelse return alloc.dupe(u8, raw);
    if (contents != .array) return alloc.dupe(u8, raw);

    var text: std.Io.Writer.Allocating = .init(alloc);
    defer text.deinit();
    var found = false;
    for (contents.array.items) |item| {
        if (item != .object) continue;
        const piece = item.object.get("text") orelse continue;
        if (piece != .string) continue;
        if (found) text.writer.writeByte('\n') catch return error.OutOfMemory;
        text.writer.writeAll(piece.string) catch return error.OutOfMemory;
        found = true;
    }
    if (!found) return alloc.dupe(u8, raw);
    return text.toOwnedSlice() catch return error.OutOfMemory;
}

fn readResourceInputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *ReadResourceInput = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return true;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

fn selectInputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *SelectInput = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}
