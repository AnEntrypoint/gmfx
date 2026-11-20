const std = @import("std");
const definitions = @import("definitions.zig");
const types = @import("../shared/types.zig");

pub const StopInput = definitions.StopInput;
pub const StopAction = definitions.StopAction;
pub const StopOutcome = definitions.StopOutcome;
pub const StopHandler = definitions.StopHandler;

pub fn buildContinuationMessage(
    alloc: std.mem.Allocator,
    context: []const u8,
) std.mem.Allocator.Error![]u8 {
    return alloc.dupe(u8, context);
}

pub fn continuationMessage(
    alloc: std.mem.Allocator,
    context: []const u8,
) std.mem.Allocator.Error!types.ChatMessage {
    return .{
        .role = .user,
        .content = try alloc.dupe(u8, context),
        .hook_trigger = .{ .name = "stop_hook" },
    };
}

pub fn joinVisibleSegments(
    alloc: std.mem.Allocator,
    first: ?[]const u8,
    second: ?[]const u8,
) std.mem.Allocator.Error![]u8 {
    const earlier = first orelse "";
    const later = second orelse "";
    if (earlier.len == 0) return alloc.dupe(u8, later);
    if (later.len == 0) return alloc.dupe(u8, earlier);
    return alloc.print("{s}\n{s}", .{ earlier, later });
}

test "Stop continuation message carries the raw hook reason" {
    const message = try buildContinuationMessage(
        std.testing.allocator,
        "verify the answer",
    );
    defer std.testing.allocator.free(message);

    try std.testing.expectEqualStrings("verify the answer", message);
}

test "Stop continuation is a system_trigger user message named stop_hook with the raw reason" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const message = try continuationMessage(arena_state.allocator(), "verify the answer");
    try std.testing.expectEqual(types.ChatRole.user, message.role);
    try std.testing.expectEqualStrings("verify the answer", message.content.?);
    try std.testing.expectEqualStrings("system_trigger", message.hook_trigger.?.origin);
    try std.testing.expectEqualStrings("stop_hook", message.hook_trigger.?.name);
}

test "visible Stop segments join with one newline" {
    const joined = try joinVisibleSegments(
        std.testing.allocator,
        "first",
        "second",
    );
    defer std.testing.allocator.free(joined);

    try std.testing.expectEqualStrings("first\nsecond", joined);
}
