const std = @import("std");
const managed_execution = @import("../../core/execution/managed_execution.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const tool_call_metrics = @import("../../core/workspace/tool_call_metrics.zig");
const wait_habits = @import("../../core/shell_command/wait_habits.zig");

const Allocator = std.mem.Allocator;

pub const description =
    "List background tasks started with Bash run_in_background that are still running, plus finished ones whose final state has not been read yet. A running task's line gives the task ID, its state, how long it has run, how long since it last printed output, the word stuck when it has been silent past the stall threshold, and its command. A finished task's line gives the task ID, its state, and its command. Read one with TaskOutput, or stop it with TaskStop. To wait, call WaitFor once instead of listing again.";

const default_limit: usize = 20;
const max_limit: i64 = 100;
const active_only_refusal = "TaskList active_only=false is not supported yet; only running tasks and finished ones not read yet are listed.";
const limit_refusal = "TaskList limit must be an integer from 1 to 100.";
const arguments_refusal = "TaskList arguments must be a JSON object with optional active_only and limit.";
const unavailable_message = "TaskList is not available in this session.";
const empty_message = "No background tasks found.";

const Arguments = struct {
    active_only: ?bool = null,
    limit: ?i64 = null,
};

pub const Input = struct {
    limit: usize,
};

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const source = if (args_json.len == 0) "{}" else args_json;
    const arguments = std.json.parseFromSliceLeaky(Arguments, arena_state.allocator(), source, .{}) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, arguments_refusal) };
    };
    if (arguments.active_only == false) {
        return .{ .failure = try ctx.allocator.dupe(u8, active_only_refusal) };
    }
    const limit = arguments.limit orelse @as(i64, default_limit);
    if (limit < 1 or limit > max_limit) {
        return .{ .failure = try ctx.allocator.dupe(u8, limit_refusal) };
    }
    return .{ .input = try wrap(ctx.allocator, .{ .limit = @intCast(limit) }) };
}

fn wrap(alloc: Allocator, input: Input) Allocator.Error!tool_dispatch.ToolInput {
    const slot = try alloc.create(Input);
    slot.* = input;
    return .{ .ptr = slot, .deinit_fn = inputDeinit };
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    alloc.destroy(input);
}

pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(Input);
    const runtime = ctx.managed_executions orelse return .{
        .failure = try ctx.allocator.dupe(u8, unavailable_message),
    };
    const items = try runtime.list(ctx.allocator);
    defer freeItems(ctx.allocator, items);
    const listing = try render(ctx.allocator, items, input.limit);
    if (tool_call_metrics.sessionMetrics().zeroWaitPolls() == 0) return .{ .success = listing };
    defer ctx.allocator.free(listing);
    return .{ .success = try std.fmt.allocPrint(ctx.allocator, "{s}\n{s}", .{ listing, wait_habits.repeated_status_note }) };
}

fn freeItems(alloc: Allocator, items: []managed_execution.ListItem) void {
    for (items) |*item| item.deinit(alloc);
    alloc.free(items);
}

pub fn render(alloc: Allocator, items: []const managed_execution.ListItem, limit: usize) Allocator.Error![]u8 {
    const shown = @min(items.len, limit);
    if (shown == 0) return alloc.dupe(u8, empty_message);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    const header = try std.fmt.allocPrint(alloc, "active_background_tasks: {d}", .{shown});
    defer alloc.free(header);
    try out.appendSlice(alloc, header);
    for (items[0..shown]) |item| {
        const line = if (std.meta.activeTag(item.state) == .running)
            try std.fmt.allocPrint(alloc, "\n- {s} {s} {d}s idle {d}s{s} {s}", .{
                item.execution_id,
                stateName(item.state),
                item.running_ms / std.time.ms_per_s,
                item.idle_ms / std.time.ms_per_s,
                if (item.stuck) " stuck" else "",
                item.command,
            })
        else
            try std.fmt.allocPrint(alloc, "\n- {s} {s} {s}", .{ item.execution_id, stateName(item.state), item.command });
        defer alloc.free(line);
        try out.appendSlice(alloc, line);
    }
    return out.toOwnedSlice(alloc);
}

fn stateName(state: managed_execution.SnapshotState) []const u8 {
    return switch (state) {
        .running => "running",
        .completed => "completed",
        .stopped => "stopped",
        .lost => "lost",
    };
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return true;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

test "TaskList defaults to running tasks and twenty entries" {
    const decoded = try decode(.{ .allocator = std.testing.allocator, .tool_call_name = "TaskList" }, "{}");
    switch (decoded) {
        .input => |input| {
            defer input.deinit(std.testing.allocator);
            try std.testing.expectEqual(default_limit, input.as(Input).limit);
        },
        .failure => |message| {
            defer std.testing.allocator.free(message);
            return error.TestExpectedEqual;
        },
    }
}

test "TaskList refuses active_only false and out of range limits" {
    const refused = [_][]const u8{
        "{\"active_only\":false}",
        "{\"limit\":0}",
        "{\"limit\":101}",
        "{\"limit\":\"ten\"}",
        "{\"unknown\":true}",
    };
    for (refused) |args| {
        const decoded = try decode(.{ .allocator = std.testing.allocator, .tool_call_name = "TaskList" }, args);
        switch (decoded) {
            .input => |input| {
                input.deinit(std.testing.allocator);
                return error.TestExpectedEqual;
            },
            .failure => |message| std.testing.allocator.free(message),
        }
    }
}

test "TaskList accepts the limit bounds" {
    const bounds = [_][]const u8{ "{\"limit\":1}", "{\"limit\":100,\"active_only\":true}" };
    for (bounds) |args| {
        const decoded = try decode(.{ .allocator = std.testing.allocator, .tool_call_name = "TaskList" }, args);
        switch (decoded) {
            .input => |input| input.deinit(std.testing.allocator),
            .failure => |message| {
                defer std.testing.allocator.free(message);
                return error.TestExpectedEqual;
            },
        }
    }
}

test "TaskList renders running tasks up to the limit" {
    const alloc = std.testing.allocator;
    var items = [_]managed_execution.ListItem{
        .{ .execution_id = try alloc.dupe(u8, "shell-1"), .command = try alloc.dupe(u8, "make"), .state = .running, .backend = .captured, .persistence = .process },
        .{ .execution_id = try alloc.dupe(u8, "shell-2"), .command = try alloc.dupe(u8, "npm test"), .state = .running, .backend = .captured, .persistence = .process },
    };
    defer for (&items) |*item| item.deinit(alloc);
    const body = try render(alloc, &items, 1);
    defer alloc.free(body);
    try std.testing.expectEqualStrings("active_background_tasks: 1\n- shell-1 running 0s idle 0s make", body);
}

test "TaskList lines give elapsed and silent time, a stuck mark, and plain finished tasks" {
    const alloc = std.testing.allocator;
    var items = [_]managed_execution.ListItem{
        .{ .execution_id = try alloc.dupe(u8, "build"), .command = try alloc.dupe(u8, "zig build"), .state = .running, .backend = .captured, .persistence = .process, .running_ms = 61_900, .idle_ms = 3_100 },
        .{ .execution_id = try alloc.dupe(u8, "shell-2"), .command = try alloc.dupe(u8, "npm test"), .state = .running, .backend = .captured, .persistence = .process, .running_ms = 400_000, .idle_ms = 190_000, .stuck = true },
        .{ .execution_id = try alloc.dupe(u8, "shell-3"), .command = try alloc.dupe(u8, "make"), .state = .{ .completed = .{ .exit_code = 0 } }, .backend = .captured, .persistence = .process, .running_ms = 5_000, .idle_ms = 5_000 },
    };
    defer for (&items) |*item| item.deinit(alloc);
    const body = try render(alloc, &items, default_limit);
    defer alloc.free(body);
    try std.testing.expectEqualStrings(
        "active_background_tasks: 3\n" ++
            "- build running 61s idle 3s zig build\n" ++
            "- shell-2 running 400s idle 190s stuck npm test\n" ++
            "- shell-3 completed make",
        body,
    );
}

test "TaskList reports an empty registry" {
    const body = try render(std.testing.allocator, &.{}, default_limit);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings(empty_message, body);
}
