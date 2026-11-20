const std = @import("std");
const goal = @import("../../core/goal/state.zig");

const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;

pub fn renderGoalResult(alloc: Allocator, snapshot: ?goal.Snapshot) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    writeGoalResult(&out.writer, snapshot) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };
    return out.toOwnedSlice();
}

fn writeGoalResult(writer: *std.Io.Writer, snapshot: ?goal.Snapshot) std.Io.Writer.Error!void {
    var json: Stringify = .{ .writer = writer, .options = .{ .whitespace = .indent_2 } };
    try json.beginObject();
    try json.objectField("goal");
    if (snapshot) |value| {
        try writeSnapshot(&json, value);
    } else {
        try json.write(null);
    }
    try json.endObject();
}

fn writeSnapshot(json: *Stringify, snapshot: goal.Snapshot) std.Io.Writer.Error!void {
    try json.beginObject();
    try json.objectField("objective");
    try json.write(snapshot.objective);
    if (snapshot.completion_criterion) |criterion| {
        try json.objectField("completionCriterion");
        try json.write(criterion);
    }
    try json.objectField("status");
    try json.write(@tagName(snapshot.status));
    try json.objectField("turnsUsed");
    try json.write(snapshot.turns_used);
    try json.objectField("tokensUsed");
    try json.write(snapshot.tokens_used);
    try json.objectField("wallClockMs");
    try json.write(snapshot.wall_clock_ms);
    try json.objectField("budget");
    try writeBudget(json, snapshot.budget);
    if (snapshot.terminal_reason) |reason| {
        try json.objectField("terminalReason");
        try json.write(reason);
    }
    try json.endObject();
}

fn writeBudget(json: *Stringify, report: goal.BudgetReport) std.Io.Writer.Error!void {
    try json.beginObject();
    try json.objectField("tokenBudget");
    try json.write(report.token_budget);
    try json.objectField("turnBudget");
    try json.write(report.turn_budget);
    try json.objectField("wallClockBudgetMs");
    try json.write(report.wall_clock_budget_ms);
    try json.objectField("remainingTokens");
    try json.write(report.remaining_tokens);
    try json.objectField("remainingTurns");
    try json.write(report.remaining_turns);
    try json.objectField("remainingWallClockMs");
    try json.write(report.remaining_wall_clock_ms);
    try json.objectField("tokenBudgetReached");
    try json.write(report.token_budget_reached);
    try json.objectField("turnBudgetReached");
    try json.write(report.turn_budget_reached);
    try json.objectField("wallClockBudgetReached");
    try json.write(report.wall_clock_budget_reached);
    try json.objectField("overBudget");
    try json.write(report.over_budget);
    try json.endObject();
}

test "GetGoal renders a null goal as an object with goal set to null" {
    const alloc = std.testing.allocator;
    const text = try renderGoalResult(alloc, null);
    defer alloc.free(text);
    try std.testing.expectEqualStrings("{\n  \"goal\": null\n}", text);
}

test "GetGoal renders the snapshot fields in Kimi's order and omits absent optional fields" {
    const alloc = std.testing.allocator;
    const snapshot = goal.Snapshot{
        .id = 9,
        .objective = "ship",
        .completion_criterion = null,
        .status = .active,
        .turns_used = 2,
        .tokens_used = 30,
        .wall_clock_ms = 4000,
        .budget = .{
            .token_budget = 100,
            .turn_budget = null,
            .wall_clock_budget_ms = null,
            .remaining_tokens = 70,
            .remaining_turns = null,
            .remaining_wall_clock_ms = null,
            .token_budget_reached = false,
            .turn_budget_reached = false,
            .wall_clock_budget_reached = false,
            .over_budget = false,
        },
        .terminal_reason = null,
    };
    const text = try renderGoalResult(alloc, snapshot);
    defer alloc.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"goalId\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"completionCriterion\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"terminalReason\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"turnBudget\": null") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"remainingTokens\": 70") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"status\": \"active\"") != null);
}
