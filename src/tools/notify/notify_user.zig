const std = @import("std");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");

const Allocator = std.mem.Allocator;

pub const description =
    "Send the user a notification with a short title and a message, for something that needs their attention while you work. It is available only in sessions that can show notifications.";

const unavailable_message = "NotifyUser is not available in this session.";
const undelivered_message = "NotifyUser cannot deliver notifications yet: this session has no notification channel.";
const shape_refusal = "NotifyUser arguments must be a JSON object with message and an optional title.";
const message_refusal = "NotifyUser message is required and cannot be empty.";
const title_refusal = "NotifyUser title cannot be empty.";

const Arguments = struct {
    title: ?[]const u8 = null,
    message: ?[]const u8 = null,
};

pub const Input = struct {
    title: ?[]u8,
    message: []u8,

    fn deinit(self: Input, alloc: Allocator) void {
        if (self.title) |title| alloc.free(title);
        alloc.free(self.message);
    }
};

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    if (!ctx.tool_capabilities.notify_user_ready) {
        return .{ .failure = try ctx.allocator.dupe(u8, unavailable_message) };
    }
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arguments = std.json.parseFromSliceLeaky(Arguments, arena_state.allocator(), args_json, .{}) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, shape_refusal) };
    };
    const message = arguments.message orelse return .{ .failure = try ctx.allocator.dupe(u8, message_refusal) };
    if (message.len == 0) return .{ .failure = try ctx.allocator.dupe(u8, message_refusal) };
    if (arguments.title) |title| {
        if (title.len == 0) return .{ .failure = try ctx.allocator.dupe(u8, title_refusal) };
    }
    const owned_message = try ctx.allocator.dupe(u8, message);
    errdefer ctx.allocator.free(owned_message);
    const owned_title: ?[]u8 = if (arguments.title) |title| try ctx.allocator.dupe(u8, title) else null;
    errdefer if (owned_title) |title| ctx.allocator.free(title);
    return .{ .input = try wrap(ctx.allocator, .{ .title = owned_title, .message = owned_message }) };
}

fn wrap(alloc: Allocator, input: Input) Allocator.Error!tool_dispatch.ToolInput {
    const slot = try alloc.create(Input);
    slot.* = input;
    return .{ .ptr = slot, .deinit_fn = inputDeinit };
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    _ = erased;
    return .{ .failure = try ctx.allocator.dupe(u8, undelivered_message) };
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return true;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

test "NotifyUser is refused when the session has no notifications" {
    const decoded = try decode(.{ .allocator = std.testing.allocator, .tool_call_name = "NotifyUser" }, "{\"message\":\"done\"}");
    switch (decoded) {
        .input => |input| {
            input.deinit(std.testing.allocator);
            return error.TestExpectedEqual;
        },
        .failure => |message| {
            defer std.testing.allocator.free(message);
            try std.testing.expectEqualStrings(unavailable_message, message);
        },
    }
}

test "NotifyUser requires a non-empty message and an optional non-empty title when enabled" {
    const enabled: tool_dispatch.ToolCapabilities = .{ .notify_user_ready = true };
    const accepted = [_][]const u8{ "{\"message\":\"done\"}", "{\"title\":\"Build\",\"message\":\"done\"}" };
    for (accepted) |args| {
        const decoded = try decode(.{ .allocator = std.testing.allocator, .tool_call_name = "NotifyUser", .tool_capabilities = enabled }, args);
        switch (decoded) {
            .input => |input| input.deinit(std.testing.allocator),
            .failure => |message| {
                defer std.testing.allocator.free(message);
                return error.TestExpectedEqual;
            },
        }
    }
    const refused = [_][]const u8{ "{}", "{\"message\":\"\"}", "{\"title\":\"\",\"message\":\"x\"}", "{\"message\":\"x\",\"extra\":1}" };
    for (refused) |args| {
        const decoded = try decode(.{ .allocator = std.testing.allocator, .tool_call_name = "NotifyUser", .tool_capabilities = enabled }, args);
        switch (decoded) {
            .input => |input| {
                input.deinit(std.testing.allocator);
                return error.TestExpectedEqual;
            },
            .failure => |message| std.testing.allocator.free(message),
        }
    }
}
