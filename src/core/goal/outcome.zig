const std = @import("std");
const state = @import("state.zig");

const Allocator = std.mem.Allocator;

const completion_instruction = "Write a concise final message for the user. State that the goal is complete, summarize the main work completed, and mention any validation you ran. Do not call more goal tools.";
const blocked_instruction = "Write a concise final message for the user. State that the goal is blocked, explain the concrete blocker, and say what input or change is needed before work can continue. Do not call more goal tools.";

pub fn completionSummaryPrompt(alloc: Allocator, completion: state.Completion) Allocator.Error![]u8 {
    const stats = try statsLine(alloc, completion.turns_used, completion.wall_clock_ms, completion.tokens_used);
    defer alloc.free(stats);
    if (completion.terminal_reason) |reason| {
        return std.fmt.allocPrint(alloc, "Goal completed successfully: {s}.\n{s}\n\n{s}", .{ reason, stats, completion_instruction });
    }
    return std.fmt.allocPrint(alloc, "Goal completed successfully.\n{s}\n\n{s}", .{ stats, completion_instruction });
}

pub fn blockedReasonPrompt(alloc: Allocator, snapshot: state.Snapshot) Allocator.Error![]u8 {
    const stats = try statsLine(alloc, snapshot.turns_used, snapshot.wall_clock_ms, snapshot.tokens_used);
    defer alloc.free(stats);
    return std.fmt.allocPrint(alloc, "Goal blocked.\n{s}\n\n{s}", .{ stats, blocked_instruction });
}

fn statsLine(alloc: Allocator, turns: u64, wall_clock_ms: u64, tokens: u64) Allocator.Error![]u8 {
    const elapsed = try formatElapsed(alloc, wall_clock_ms);
    defer alloc.free(elapsed);
    const used = try formatTokens(alloc, tokens);
    defer alloc.free(used);
    const turn_word: []const u8 = if (turns == 1) "turn" else "turns";
    return std.fmt.allocPrint(alloc, "Worked {d} {s} over {s}, using {s} tokens.", .{ turns, turn_word, elapsed, used });
}

pub fn formatElapsed(alloc: Allocator, ms: u64) Allocator.Error![]u8 {
    const total_seconds = (ms + 500) / 1000;
    if (total_seconds < 60) return std.fmt.allocPrint(alloc, "{d}s", .{total_seconds});
    const minutes = total_seconds / 60;
    const seconds = total_seconds % 60;
    if (minutes < 60) return std.fmt.allocPrint(alloc, "{d}m{d:0>2}s", .{ minutes, seconds });
    return std.fmt.allocPrint(alloc, "{d}h{d:0>2}m", .{ minutes / 60, minutes % 60 });
}

pub fn formatTokens(alloc: Allocator, tokens: u64) Allocator.Error![]u8 {
    if (tokens < 1000) return std.fmt.allocPrint(alloc, "{d}", .{tokens});
    if (tokens < 1_000_000) return std.fmt.allocPrint(alloc, "{d:.1}k", .{@as(f64, @floatFromInt(tokens)) / 1000.0});
    return std.fmt.allocPrint(alloc, "{d:.1}M", .{@as(f64, @floatFromInt(tokens)) / 1_000_000.0});
}

test "completion summary names the reason and the stats" {
    const alloc = std.testing.allocator;
    const text = try completionSummaryPrompt(alloc, .{ .turns_used = 1, .tokens_used = 1500, .wall_clock_ms = 90_000, .terminal_reason = null });
    defer alloc.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text, "Goal completed successfully.\nWorked 1 turn over 1m30s, using 1.5k tokens.\n\nWrite a concise final message"));
}

test "completion summary includes a reason when one is given" {
    const alloc = std.testing.allocator;
    const text = try completionSummaryPrompt(alloc, .{ .turns_used = 3, .tokens_used = 0, .wall_clock_ms = 4000, .terminal_reason = "tests green" });
    defer alloc.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text, "Goal completed successfully: tests green.\nWorked 3 turns over 4s, using 0 tokens."));
}

test "blocked prompt states the blocker request and the stats" {
    const alloc = std.testing.allocator;
    const snapshot = state.Snapshot{
        .id = 1,
        .objective = "goal",
        .completion_criterion = null,
        .status = .blocked,
        .turns_used = 2,
        .tokens_used = 2_500_000,
        .wall_clock_ms = 3_725_000,
        .budget = .{
            .token_budget = null,
            .turn_budget = null,
            .wall_clock_budget_ms = null,
            .remaining_tokens = null,
            .remaining_turns = null,
            .remaining_wall_clock_ms = null,
            .token_budget_reached = false,
            .turn_budget_reached = false,
            .wall_clock_budget_reached = false,
            .over_budget = false,
        },
        .terminal_reason = "needs credentials",
    };
    const text = try blockedReasonPrompt(alloc, snapshot);
    defer alloc.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text, "Goal blocked.\nWorked 2 turns over 1h02m, using 2.5M tokens.\n\nWrite a concise final message"));
}

test "formatElapsed rounds to whole seconds and uses hours past sixty minutes" {
    const alloc = std.testing.allocator;
    const short = try formatElapsed(alloc, 1499);
    defer alloc.free(short);
    try std.testing.expectEqualStrings("1s", short);
    const minutes = try formatElapsed(alloc, 61_000);
    defer alloc.free(minutes);
    try std.testing.expectEqualStrings("1m01s", minutes);
}
