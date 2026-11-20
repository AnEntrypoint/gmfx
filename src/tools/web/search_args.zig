const std = @import("std");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");

const Allocator = std.mem.Allocator;

pub const Input = struct {
    query: []u8,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.query);
        self.* = .{ .query = &.{} };
    }
};

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "WebSearch arguments must be valid JSON") };
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return .{ .failure = try ctx.allocator.dupe(u8, "WebSearch arguments must be an object") };
    }
    if (unknownField(parsed.value.object)) |field| {
        return .{ .failure = try ctx.allocator.print("WebSearch field \"{s}\" is not supported", .{field}) };
    }

    const query_value = parsed.value.object.get("query") orelse {
        return .{ .failure = try ctx.allocator.dupe(u8, "WebSearch field \"query\" is required") };
    };
    if (query_value != .string) {
        return .{ .failure = try ctx.allocator.dupe(u8, "WebSearch field \"query\" must be a string") };
    }
    const query_len = std.unicode.utf8CountCodepoints(query_value.string) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "WebSearch field \"query\" must be valid UTF-8") };
    };
    if (query_len < 2) {
        return .{ .failure = try ctx.allocator.dupe(u8, "WebSearch field \"query\" must contain at least two characters") };
    }

    const query = try ctx.allocator.dupe(u8, query_value.string);
    errdefer ctx.allocator.free(query);
    const input = try ctx.allocator.create(Input);
    input.* = .{ .query = query };
    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return true;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

fn unknownField(object: std.json.ObjectMap) ?[]const u8 {
    var fields = object.iterator();
    while (fields.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "query")) continue;
        return entry.key_ptr.*;
    }
    return null;
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}
