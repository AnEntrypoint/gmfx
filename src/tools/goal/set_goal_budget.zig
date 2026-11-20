const std = @import("std");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const goal = @import("../../core/goal/state.zig");
const shared = @import("shared.zig");

const Allocator = std.mem.Allocator;
const DispatchContext = tool_dispatch.DispatchContext;
const ToolInput = tool_dispatch.ToolInput;
const ToolResult = tool_dispatch.ToolResult;

pub const description =
    \\Set a hard budget for the current goal, only when the user clearly states one, such as "stop after 20 turns", "use no more than 500k tokens", or "finish within 30 minutes". Do not invent limits, and do not set one for vague wording such as "spend some time" or "try to be quick". Convert a compound time to one unit first: "2 hours and 3 minutes" → `value: 123, unit: "minutes"`.
;

const invalid_arguments_message = "SetGoalBudget arguments must be an object with value (positive number) and unit (turns, tokens, milliseconds, seconds, minutes or hours).";
const allowed_fields = [_][]const u8{ "value", "unit" };
const no_goal_message = "Goal budget not set: no current goal.";
const changed_goal_message = "Goal budget not set: the current goal changed.";
const exhausted_suffix = " The goal has already reached this budget and will stop now.";

pub const Unit = enum {
    turns,
    tokens,
    milliseconds,
    seconds,
    minutes,
    hours,
};

pub const Input = struct {
    value: f64,
    unit: Unit,
    budget: ?goal.Budget,
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
    const raw_value = object.get("value") orelse return shared.decodeFailure(ctx.allocator, invalid_arguments_message);
    const number = shared.numberValue(raw_value) orelse return shared.decodeFailure(ctx.allocator, invalid_arguments_message);
    if (!(number > 0) or !std.math.isFinite(number)) return shared.decodeFailure(ctx.allocator, invalid_arguments_message);
    const unit_text = shared.stringValue(object.get("unit") orelse return shared.decodeFailure(ctx.allocator, invalid_arguments_message)) orelse
        return shared.decodeFailure(ctx.allocator, invalid_arguments_message);
    const unit = std.meta.stringToEnum(Unit, unit_text) orelse return shared.decodeFailure(ctx.allocator, invalid_arguments_message);

    const value = normalizeValue(number, unit);
    const budget = budgetFor(value, unit);
    const current = if (ctx.goal) |view| view.state.snapshot(view.now_ms) else null;
    const stop_batch = if (budget) |next| if (current) |snapshot| wouldExceedBudget(snapshot, next) else false else false;
    const input = Input{
        .value = value,
        .unit = unit,
        .budget = budget,
        .goal_id_at_decode = if (current) |snapshot| snapshot.id else null,
        .stop_batch = stop_batch,
    };
    return .{ .input = try shared.wrap(Input, ctx.allocator, input) };
}

fn normalizeValue(value: f64, unit: Unit) f64 {
    return switch (unit) {
        .turns, .tokens => @max(1, roundHalfUp(value)),
        .milliseconds, .seconds, .minutes, .hours => value,
    };
}

fn roundHalfUp(value: f64) f64 {
    return @floor(value + 0.5);
}

const u64_limit: f64 = 18_446_744_073_709_551_616.0;
const min_time_budget_ms: f64 = @floatFromInt(goal.min_time_budget_ms);

fn budgetFor(value: f64, unit: Unit) ?goal.Budget {
    switch (unit) {
        .turns => {
            if (value >= u64_limit) return null;
            return .{ .turn_budget = @intFromFloat(value) };
        },
        .tokens => {
            if (value >= u64_limit) return null;
            return .{ .token_budget = @intFromFloat(value) };
        },
        .milliseconds, .seconds, .minutes, .hours => {
            const ms = roundHalfUp(toMilliseconds(value, unit));
            if (!std.math.isFinite(ms) or ms < min_time_budget_ms or ms >= u64_limit) return null;
            return .{ .wall_clock_budget_ms = @intFromFloat(ms) };
        },
    }
}

fn toMilliseconds(value: f64, unit: Unit) f64 {
    return switch (unit) {
        .turns, .tokens, .milliseconds => value,
        .seconds => value * 1000,
        .minutes => value * 60 * 1000,
        .hours => value * 60 * 60 * 1000,
    };
}

fn wouldExceedBudget(current: goal.Snapshot, next: goal.Budget) bool {
    const turn_limit = next.turn_budget orelse current.budget.turn_budget;
    const token_limit = next.token_budget orelse current.budget.token_budget;
    const wall_limit = next.wall_clock_budget_ms orelse current.budget.wall_clock_budget_ms;
    if (turn_limit) |limit| {
        if (current.turns_used >= limit) return true;
    }
    if (token_limit) |limit| {
        if (current.tokens_used >= limit) return true;
    }
    if (wall_limit) |limit| {
        if (current.wall_clock_ms >= limit) return true;
    }
    return false;
}

pub fn call(ctx: DispatchContext, erased: ToolInput) tool_dispatch.DispatchError!ToolResult {
    const input = erased.as(Input);
    const view = ctx.goal orelse return shared.unavailable(ctx.allocator);
    const current = view.state.snapshot(view.now_ms) orelse
        return shared.successResult(ctx.allocator, no_goal_message);
    if (current.id != input.goal_id_at_decode) {
        return shared.successResult(ctx.allocator, changed_goal_message);
    }
    const label = try formatBudget(ctx.allocator, input.value, input.unit);
    defer ctx.allocator.free(label);
    const budget = input.budget orelse {
        const text = try std.fmt.allocPrint(ctx.allocator, "Goal budget not set: {s} is not a reasonable goal budget.", .{label});
        return .{ .success = text };
    };
    const snapshot = view.state.setBudget(view.alloc, view.now_ms, budget) catch |err| return shared.goalFailure(ctx.allocator, err);
    if (snapshot.budget.over_budget) {
        input.stop_turn = true;
        return .{ .success = try std.fmt.allocPrint(ctx.allocator, "Goal budget set: {s}.{s}", .{ label, exhausted_suffix }) };
    }
    return .{ .success = try std.fmt.allocPrint(ctx.allocator, "Goal budget set: {s}.", .{label}) };
}

fn formatBudget(alloc: Allocator, value: f64, unit: Unit) Allocator.Error![]u8 {
    const number = try formatNumber(alloc, value);
    defer alloc.free(number);
    const shown = if (value == 1) singular(unit) else @tagName(unit);
    return std.fmt.allocPrint(alloc, "{s} {s}", .{ number, shown });
}

fn formatNumber(alloc: Allocator, value: f64) Allocator.Error![]u8 {
    if (value == @floor(value) and value < 1e15) {
        return std.fmt.allocPrint(alloc, "{d}", .{@as(u64, @intFromFloat(value))});
    }
    return std.fmt.allocPrint(alloc, "{d}", .{value});
}

fn singular(unit: Unit) []const u8 {
    return switch (unit) {
        .turns => "turn",
        .tokens => "token",
        .milliseconds => "millisecond",
        .seconds => "second",
        .minutes => "minute",
        .hours => "hour",
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

fn expectSuccessText(result: ToolResult, expected: []const u8) !void {
    switch (result) {
        .success => |body| try std.testing.expectEqualStrings(expected, body),
        else => return error.TestUnexpectedResult,
    }
}

test "SetGoalBudget rounds turns and tokens to whole units with a floor of one" {
    const alloc = std.testing.allocator;
    const ctx = DispatchContext{ .allocator = alloc };
    const rounded = try decodeInput(alloc, ctx, "{\"value\":2.4,\"unit\":\"turns\"}");
    defer rounded.deinit(alloc);
    try std.testing.expectEqual(@as(?u64, 2), rounded.as(Input).budget.?.turn_budget);
    const floored = try decodeInput(alloc, ctx, "{\"value\":0.2,\"unit\":\"tokens\"}");
    defer floored.deinit(alloc);
    try std.testing.expectEqual(@as(?u64, 1), floored.as(Input).budget.?.token_budget);
}

test "SetGoalBudget converts time units to milliseconds" {
    const alloc = std.testing.allocator;
    const ctx = DispatchContext{ .allocator = alloc };
    const compound = try decodeInput(alloc, ctx, "{\"value\":123,\"unit\":\"minutes\"}");
    defer compound.deinit(alloc);
    try std.testing.expectEqual(@as(?u64, 7_380_000), compound.as(Input).budget.?.wall_clock_budget_ms);
    const hours = try decodeInput(alloc, ctx, "{\"value\":1.5,\"unit\":\"hours\"}");
    defer hours.deinit(alloc);
    try std.testing.expectEqual(@as(?u64, 5_400_000), hours.as(Input).budget.?.wall_clock_budget_ms);
}

test "SetGoalBudget rejects a zero value, a negative value and an unknown unit at decode" {
    const alloc = std.testing.allocator;
    const ctx = DispatchContext{ .allocator = alloc };
    const cases = [_][]const u8{
        "{\"value\":0,\"unit\":\"turns\"}",
        "{\"value\":-3,\"unit\":\"turns\"}",
        "{\"value\":2,\"unit\":\"days\"}",
        "{\"unit\":\"turns\"}",
        "{\"value\":2,\"unit\":\"turns\",\"extra\":true}",
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
                try std.testing.expectEqualStrings(invalid_arguments_message, failure);
            },
        }
    }
}

test "SetGoalBudget reports that a time budget under one second is not reasonable" {
    const alloc = std.testing.allocator;
    var state: goal.State = .{};
    defer state.deinit(alloc);
    _ = try state.create(alloc, 0, "goal", null, false);
    const ctx = DispatchContext{ .allocator = alloc, .goal = .{ .state = &state, .alloc = alloc, .now_ms = 0 } };
    const input = try decodeInput(alloc, ctx, "{\"value\":0.5,\"unit\":\"seconds\"}");
    defer input.deinit(alloc);
    const result = try call(ctx, input);
    defer result.deinit(alloc);
    try expectSuccessText(result, "Goal budget not set: 0.5 seconds is not a reasonable goal budget.");
}

test "SetGoalBudget sets the budget on the current goal and names the singular unit" {
    const alloc = std.testing.allocator;
    var state: goal.State = .{};
    defer state.deinit(alloc);
    _ = try state.create(alloc, 0, "goal", null, false);
    const ctx = DispatchContext{ .allocator = alloc, .goal = .{ .state = &state, .alloc = alloc, .now_ms = 0 } };
    const input = try decodeInput(alloc, ctx, "{\"value\":1,\"unit\":\"hours\"}");
    defer input.deinit(alloc);
    const result = try call(ctx, input);
    defer result.deinit(alloc);
    try expectSuccessText(result, "Goal budget set: 1 hour.");
    try std.testing.expect(!stopsTurn(input));
    try std.testing.expectEqual(@as(?u64, 3_600_000), state.snapshot(0).?.budget.wall_clock_budget_ms);
}

test "SetGoalBudget stops the turn when the goal has already reached the new budget" {
    const alloc = std.testing.allocator;
    var state: goal.State = .{};
    defer state.deinit(alloc);
    _ = try state.create(alloc, 0, "goal", null, false);
    _ = state.recordTurn(0);
    _ = state.recordTurn(0);
    const ctx = DispatchContext{ .allocator = alloc, .goal = .{ .state = &state, .alloc = alloc, .now_ms = 0 } };
    const input = try decodeInput(alloc, ctx, "{\"value\":2,\"unit\":\"turns\"}");
    defer input.deinit(alloc);
    try std.testing.expect(stopsBatch(input));
    const result = try call(ctx, input);
    defer result.deinit(alloc);
    try expectSuccessText(result, "Goal budget set: 2 turns. The goal has already reached this budget and will stop now.");
    try std.testing.expect(stopsTurn(input));
}

test "SetGoalBudget reports no current goal and a changed goal" {
    const alloc = std.testing.allocator;
    var state: goal.State = .{};
    defer state.deinit(alloc);
    const empty_ctx = DispatchContext{ .allocator = alloc, .goal = .{ .state = &state, .alloc = alloc, .now_ms = 0 } };
    const no_goal = try decodeInput(alloc, empty_ctx, "{\"value\":3,\"unit\":\"turns\"}");
    defer no_goal.deinit(alloc);
    const missing = try call(empty_ctx, no_goal);
    defer missing.deinit(alloc);
    try expectSuccessText(missing, no_goal_message);

    _ = try state.create(alloc, 0, "first", null, false);
    const ctx = DispatchContext{ .allocator = alloc, .goal = .{ .state = &state, .alloc = alloc, .now_ms = 0 } };
    const decoded_for_first = try decodeInput(alloc, ctx, "{\"value\":3,\"unit\":\"turns\"}");
    defer decoded_for_first.deinit(alloc);
    state.clear(alloc);
    _ = try state.create(alloc, 0, "second", null, false);
    const changed = try call(ctx, decoded_for_first);
    defer changed.deinit(alloc);
    try expectSuccessText(changed, changed_goal_message);
}
