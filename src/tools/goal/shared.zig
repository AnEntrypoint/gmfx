const std = @import("std");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const goal = @import("../../core/goal/state.zig");

const Allocator = std.mem.Allocator;

pub const ToolInput = tool_dispatch.ToolInput;
pub const DecodeResult = tool_dispatch.DecodeResult;
pub const DispatchContext = tool_dispatch.DispatchContext;
pub const DispatchError = tool_dispatch.DispatchError;
pub const ToolResult = tool_dispatch.ToolResult;

pub const main_agent_only_message = "Goal tools are only supported by the main agent.";

pub fn decodeFailure(alloc: Allocator, text: []const u8) Allocator.Error!DecodeResult {
    return .{ .failure = try alloc.dupe(u8, text) };
}

pub fn successResult(alloc: Allocator, text: []const u8) Allocator.Error!ToolResult {
    return .{ .success = try alloc.dupe(u8, text) };
}

pub fn failureResult(alloc: Allocator, text: []const u8) Allocator.Error!ToolResult {
    return .{ .failure = try alloc.dupe(u8, text) };
}

pub fn goalFailure(alloc: Allocator, err: goal.GoalError) DispatchError!ToolResult {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    return failureResult(alloc, goal.errorMessage(err));
}

pub fn unavailable(alloc: Allocator) Allocator.Error!ToolResult {
    return failureResult(alloc, main_agent_only_message);
}

pub fn wrap(comptime T: type, alloc: Allocator, value: T) Allocator.Error!ToolInput {
    const slot = try alloc.create(T);
    slot.* = value;
    return .{
        .ptr = slot,
        .deinit_fn = struct {
            fn deinit(ptr: *anyopaque, a: Allocator) void {
                const typed: *T = @ptrCast(@alignCast(ptr));
                if (@hasDecl(T, "deinit")) typed.deinit(a);
                a.destroy(typed);
            }
        }.deinit,
    };
}

pub fn parseObject(alloc: Allocator, args_json: []const u8) Allocator.Error!?std.json.Parsed(std.json.Value) {
    const source = if (args_json.len == 0) "{}" else args_json;
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, source, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    if (parsed.value != .object) {
        parsed.deinit();
        return null;
    }
    return parsed;
}

pub fn unknownField(object: std.json.ObjectMap, allowed: []const []const u8) ?[]const u8 {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        var known = false;
        for (allowed) |name| {
            if (std.mem.eql(u8, entry.key_ptr.*, name)) known = true;
        }
        if (!known) return entry.key_ptr.*;
    }
    return null;
}

pub fn numberValue(value: std.json.Value) ?f64 {
    return switch (value) {
        .integer => |int| @floatFromInt(int),
        .float => |float| float,
        else => null,
    };
}

pub fn stringValue(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

test "unknownField reports the first key outside the allowed set" {
    const alloc = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, "{\"objective\":\"x\",\"extra\":1}", .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("extra", unknownField(parsed.value.object, &.{"objective"}).?);
    try std.testing.expect(unknownField(parsed.value.object, &.{ "objective", "extra" }) == null);
}

test "parseObject treats an empty argument string as an empty object and rejects arrays" {
    const alloc = std.testing.allocator;
    const empty = (try parseObject(alloc, "")).?;
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.value.object.count());
    try std.testing.expect((try parseObject(alloc, "[1]")) == null);
    try std.testing.expect((try parseObject(alloc, "{")) == null);
}
