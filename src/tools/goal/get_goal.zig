const std = @import("std");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const goal = @import("../../core/goal/state.zig");
const shared = @import("shared.zig");
const serialize = @import("serialize.zig");

const Allocator = std.mem.Allocator;
const DispatchContext = tool_dispatch.DispatchContext;
const ToolInput = tool_dispatch.ToolInput;
const ToolResult = tool_dispatch.ToolResult;

pub const description =
    \\Read the current goal: its objective, completion criterion, status, budgets with what remains of each, and the terminal reason once it has stopped. Returns `{ "goal": null }` when there is no current goal.
;

const invalid_arguments_message = "GetGoal takes no arguments.";

pub const Input = struct {};

pub fn decode(ctx: DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    const parsed = (try shared.parseObject(ctx.allocator, args_json)) orelse
        return shared.decodeFailure(ctx.allocator, invalid_arguments_message);
    defer parsed.deinit();
    if (parsed.value.object.count() != 0) return shared.decodeFailure(ctx.allocator, invalid_arguments_message);
    return .{ .input = try shared.wrap(Input, ctx.allocator, .{}) };
}

pub fn call(ctx: DispatchContext, _: ToolInput) tool_dispatch.DispatchError!ToolResult {
    const view = ctx.goal orelse return shared.unavailable(ctx.allocator);
    return .{ .success = try serialize.renderGoalResult(ctx.allocator, view.state.snapshot(view.now_ms)) };
}

pub fn readsOnly(_: ToolInput) bool {
    return true;
}

pub fn isIrreversible(_: ToolInput) bool {
    return false;
}

test "GetGoal decodes an empty object and rejects any argument" {
    const alloc = std.testing.allocator;
    const ctx = DispatchContext{ .allocator = alloc };
    const decoded = try decode(ctx, "{}");
    switch (decoded) {
        .input => |input| input.deinit(alloc),
        .failure => return error.TestUnexpectedResult,
    }
    const rejected = try decode(ctx, "{\"goal\":1}");
    switch (rejected) {
        .input => |input| {
            input.deinit(alloc);
            return error.TestUnexpectedResult;
        },
        .failure => |failure| {
            defer alloc.free(failure);
            try std.testing.expectEqualStrings(invalid_arguments_message, failure);
        },
    }
}

test "GetGoal returns a null goal when there is no current goal" {
    const alloc = std.testing.allocator;
    var state: goal.State = .{};
    defer state.deinit(alloc);
    const ctx = DispatchContext{ .allocator = alloc, .goal = .{ .state = &state, .alloc = alloc, .now_ms = 0 } };
    const input = try shared.wrap(Input, alloc, .{});
    defer input.deinit(alloc);
    const result = try call(ctx, input);
    defer result.deinit(alloc);
    switch (result) {
        .success => |body| try std.testing.expectEqualStrings("{\n  \"goal\": null\n}", body),
        else => return error.TestUnexpectedResult,
    }
}

test "GetGoal returns the live snapshot with remaining budget" {
    const alloc = std.testing.allocator;
    var state: goal.State = .{};
    defer state.deinit(alloc);
    _ = try state.create(alloc, 0, "ship it", null, false);
    _ = try state.setBudget(alloc, 0, .{ .turn_budget = 5 });
    _ = state.recordTurn(1000);
    const ctx = DispatchContext{ .allocator = alloc, .goal = .{ .state = &state, .alloc = alloc, .now_ms = 2000 } };
    const input = try shared.wrap(Input, alloc, .{});
    defer input.deinit(alloc);
    const result = try call(ctx, input);
    defer result.deinit(alloc);
    switch (result) {
        .success => |body| {
            try std.testing.expect(std.mem.indexOf(u8, body, "\"remainingTurns\": 4") != null);
            try std.testing.expect(std.mem.indexOf(u8, body, "\"wallClockMs\": 2000") != null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "GetGoal is unavailable without a goal view" {
    const alloc = std.testing.allocator;
    const ctx = DispatchContext{ .allocator = alloc };
    const input = try shared.wrap(Input, alloc, .{});
    defer input.deinit(alloc);
    const result = try call(ctx, input);
    defer result.deinit(alloc);
    switch (result) {
        .failure => |body| try std.testing.expectEqualStrings(shared.main_agent_only_message, body),
        else => return error.TestUnexpectedResult,
    }
}
