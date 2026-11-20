const std = @import("std");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const goal = @import("../../core/goal/state.zig");
const outcome = @import("../../core/goal/outcome.zig");
const shared = @import("shared.zig");

const Allocator = std.mem.Allocator;
const DispatchContext = tool_dispatch.DispatchContext;
const ToolInput = tool_dispatch.ToolInput;
const ToolResult = tool_dispatch.ToolResult;

pub const description =
    \\Set the status of the current goal. `active` resumes a paused or blocked goal when the user explicitly asks you to work on it again. `complete` and `blocked` end autonomous work: while a goal is active, its full reminder states exactly when each one is warranted; later reminders keep the current goal state and point back to those rules. Follow them, and do not call this tool merely because you finished a slice of work. After `complete` or `blocked`, write the completion summary or the blocker explanation in your next message.
;

const invalid_arguments_message = "UpdateGoal arguments must be an object with status (active, complete or blocked).";
const invalid_status_message = "Invalid goal status. Use `active`, `complete`, or `blocked`.";
const allowed_fields = [_][]const u8{"status"};

pub const Status = enum {
    active,
    complete,
    blocked,
};

pub const Input = struct {
    status: Status,
    goal_id_at_decode: ?u64,
    stop_batch: bool,
    stop_turn: bool = false,
};

pub fn decode(ctx: DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    const parsed = (try shared.parseObject(ctx.allocator, args_json)) orelse
        return shared.decodeFailure(ctx.allocator, invalid_arguments_message);
    defer parsed.deinit();
    const object = parsed.value.object;
    if (shared.unknownField(object, &allowed_fields) != null) {
        return shared.decodeFailure(ctx.allocator, invalid_arguments_message);
    }
    const status_value = object.get("status") orelse return shared.decodeFailure(ctx.allocator, invalid_arguments_message);
    const status_text = shared.stringValue(status_value) orelse return shared.decodeFailure(ctx.allocator, invalid_status_message);
    const status = std.meta.stringToEnum(Status, status_text) orelse return shared.decodeFailure(ctx.allocator, invalid_status_message);
    const current = if (ctx.goal) |view| view.state.snapshot(view.now_ms) else null;
    const goal_active = if (current) |snapshot| snapshot.status == .active else false;
    const input = Input{
        .status = status,
        .goal_id_at_decode = if (current) |snapshot| snapshot.id else null,
        .stop_batch = status != .active and goal_active,
    };
    return .{ .input = try shared.wrap(Input, ctx.allocator, input) };
}

pub fn call(ctx: DispatchContext, erased: ToolInput) tool_dispatch.DispatchError!ToolResult {
    const input = erased.as(Input);
    const view = ctx.goal orelse return shared.unavailable(ctx.allocator);
    const current = view.state.snapshot(view.now_ms);
    if (current == null or (input.goal_id_at_decode == null and input.status == .active)) {
        return shared.successResult(ctx.allocator, missingGoalMessage(input.status));
    }
    if (current.?.id != input.goal_id_at_decode) {
        return shared.successResult(ctx.allocator, changedGoalMessage(input.status));
    }
    switch (input.status) {
        .active => {
            _ = view.state.resumeGoal(view.alloc, view.now_ms) catch |err| return shared.goalFailure(ctx.allocator, err);
            return shared.successResult(ctx.allocator, "Goal resumed.");
        },
        .complete => {
            const completion = view.state.markComplete(view.alloc, view.now_ms, null) catch |err| return shared.goalFailure(ctx.allocator, err);
            const finished = completion orelse return shared.successResult(ctx.allocator, "Goal not completed: no active goal.");
            input.stop_turn = true;
            return .{ .success = try outcome.completionSummaryPrompt(ctx.allocator, finished) };
        },
        .blocked => {
            const snapshot = view.state.markBlocked(view.alloc, view.now_ms, null) catch |err| return shared.goalFailure(ctx.allocator, err);
            const blocked = snapshot orelse return shared.successResult(ctx.allocator, "Goal not blocked: no active goal.");
            input.stop_turn = true;
            return .{ .success = try outcome.blockedReasonPrompt(ctx.allocator, blocked) };
        },
    }
}

fn missingGoalMessage(status: Status) []const u8 {
    return switch (status) {
        .active => "Goal not resumed: no current goal.",
        .complete => "Goal not completed: no active goal.",
        .blocked => "Goal not blocked: no active goal.",
    };
}

fn changedGoalMessage(status: Status) []const u8 {
    return switch (status) {
        .active => "Goal not resumed: the current goal changed.",
        .complete => "Goal not completed: the current goal changed.",
        .blocked => "Goal not blocked: the current goal changed.",
    };
}

pub fn readsOnly(_: ToolInput) bool {
    return false;
}

pub fn isIrreversible(_: ToolInput) bool {
    return false;
}

pub fn stopsBatch(input: ToolInput) bool {
    return input.as(Input).stop_batch;
}

pub fn stopsTurn(input: ToolInput) bool {
    return input.as(Input).stop_turn;
}

fn decodeInput(alloc: Allocator, ctx: DispatchContext, args_json: []const u8) !ToolInput {
    const decoded = try decode(ctx, args_json);
    switch (decoded) {
        .input => |input| return input,
        .failure => |failure| {
            defer alloc.free(failure);
            return error.TestUnexpectedResult;
        },
    }
}

fn expectSuccessPrefix(result: ToolResult, prefix: []const u8) !void {
    switch (result) {
        .success => |body| try std.testing.expect(std.mem.startsWith(u8, body, prefix)),
        else => return error.TestUnexpectedResult,
    }
}

fn expectSuccessText(result: ToolResult, expected: []const u8) !void {
    switch (result) {
        .success => |body| try std.testing.expectEqualStrings(expected, body),
        else => return error.TestUnexpectedResult,
    }
}

test "UpdateGoal decodes complete, blocked and active and rejects anything else" {
    const alloc = std.testing.allocator;
    const ctx = DispatchContext{ .allocator = alloc };
    inline for (.{ "active", "complete", "blocked" }) |name| {
        const input = try decodeInput(alloc, ctx, "{\"status\":\"" ++ name ++ "\"}");
        defer input.deinit(alloc);
    }
    const cases = [_][]const u8{
        "{\"status\":\"paused\"}",
        "{}",
        "{\"status\":\"complete\",\"reason\":\"x\"}",
        "{\"status\":3}",
    };
    for (cases) |args_json| {
        const decoded = try decode(ctx, args_json);
        switch (decoded) {
            .input => |input| {
                input.deinit(alloc);
                return error.TestUnexpectedResult;
            },
            .failure => |failure| {
                defer alloc.free(failure);
                try std.testing.expect(failure.len > 0);
            },
        }
    }
}

test "UpdateGoal complete ends the goal with the completion summary and stops the turn" {
    const alloc = std.testing.allocator;
    var state: goal.State = .{};
    defer state.deinit(alloc);
    _ = try state.create(alloc, 0, "ship it", null, false);
    const ctx = DispatchContext{ .allocator = alloc, .goal = .{ .state = &state, .alloc = alloc, .now_ms = 1500 } };
    const input = try decodeInput(alloc, ctx, "{\"status\":\"complete\"}");
    defer input.deinit(alloc);
    try std.testing.expect(stopsBatch(input));
    const result = try call(ctx, input);
    defer result.deinit(alloc);
    try expectSuccessPrefix(result, "Goal completed successfully.\nWorked 0 turns over 2s, using 0 tokens.\n\nWrite a concise final message");
    try std.testing.expect(stopsTurn(input));
    try std.testing.expect(state.currentId() == null);
}

test "UpdateGoal blocked keeps the goal with a blocker prompt" {
    const alloc = std.testing.allocator;
    var state: goal.State = .{};
    defer state.deinit(alloc);
    _ = try state.create(alloc, 0, "ship it", null, false);
    const ctx = DispatchContext{ .allocator = alloc, .goal = .{ .state = &state, .alloc = alloc, .now_ms = 0 } };
    const input = try decodeInput(alloc, ctx, "{\"status\":\"blocked\"}");
    defer input.deinit(alloc);
    const result = try call(ctx, input);
    defer result.deinit(alloc);
    try expectSuccessPrefix(result, "Goal blocked.\n");
    try std.testing.expect(stopsTurn(input));
    try std.testing.expectEqual(goal.Status.blocked, state.snapshot(0).?.status);
}

test "UpdateGoal active resumes a blocked goal and does not stop the turn" {
    const alloc = std.testing.allocator;
    var state: goal.State = .{};
    defer state.deinit(alloc);
    _ = try state.create(alloc, 0, "ship it", null, false);
    _ = try state.markBlocked(alloc, 0, "waiting");
    const ctx = DispatchContext{ .allocator = alloc, .goal = .{ .state = &state, .alloc = alloc, .now_ms = 10 } };
    const input = try decodeInput(alloc, ctx, "{\"status\":\"active\"}");
    defer input.deinit(alloc);
    try std.testing.expect(!stopsBatch(input));
    const result = try call(ctx, input);
    defer result.deinit(alloc);
    try expectSuccessText(result, "Goal resumed.");
    try std.testing.expect(!stopsTurn(input));
    try std.testing.expectEqual(goal.Status.active, state.snapshot(10).?.status);
}

test "UpdateGoal reports a missing goal for each status" {
    const alloc = std.testing.allocator;
    var state: goal.State = .{};
    defer state.deinit(alloc);
    const ctx = DispatchContext{ .allocator = alloc, .goal = .{ .state = &state, .alloc = alloc, .now_ms = 0 } };
    const cases = [_]struct { args: []const u8, message: []const u8 }{
        .{ .args = "{\"status\":\"active\"}", .message = "Goal not resumed: no current goal." },
        .{ .args = "{\"status\":\"complete\"}", .message = "Goal not completed: no active goal." },
        .{ .args = "{\"status\":\"blocked\"}", .message = "Goal not blocked: no active goal." },
    };
    for (cases) |case| {
        const input = try decodeInput(alloc, ctx, case.args);
        defer input.deinit(alloc);
        const result = try call(ctx, input);
        defer result.deinit(alloc);
        try expectSuccessText(result, case.message);
    }
}

test "UpdateGoal reports a changed goal when the goal was replaced after decode" {
    const alloc = std.testing.allocator;
    var state: goal.State = .{};
    defer state.deinit(alloc);
    _ = try state.create(alloc, 0, "first", null, false);
    const ctx = DispatchContext{ .allocator = alloc, .goal = .{ .state = &state, .alloc = alloc, .now_ms = 0 } };
    const input = try decodeInput(alloc, ctx, "{\"status\":\"blocked\"}");
    defer input.deinit(alloc);
    state.clear(alloc);
    _ = try state.create(alloc, 0, "second", null, false);
    const result = try call(ctx, input);
    defer result.deinit(alloc);
    try expectSuccessText(result, "Goal not blocked: the current goal changed.");
    try std.testing.expect(!stopsTurn(input));
}

test "UpdateGoal is unavailable without a goal view" {
    const alloc = std.testing.allocator;
    const ctx = DispatchContext{ .allocator = alloc };
    const input = try decodeInput(alloc, ctx, "{\"status\":\"complete\"}");
    defer input.deinit(alloc);
    const result = try call(ctx, input);
    defer result.deinit(alloc);
    switch (result) {
        .failure => |body| try std.testing.expectEqualStrings(shared.main_agent_only_message, body),
        else => return error.TestUnexpectedResult,
    }
}
