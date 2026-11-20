const std = @import("std");

const Allocator = std.mem.Allocator;

pub const max_objective_units: usize = 4000;
pub const max_completion_criterion_units: usize = 4000;
pub const min_time_budget_ms: u64 = 1000;
pub const budget_block_prefix = "Blocked after goal budget reached";

pub const Status = enum {
    active,
    paused,
    blocked,
    complete,
};

pub const Budget = struct {
    token_budget: ?u64 = null,
    turn_budget: ?u64 = null,
    wall_clock_budget_ms: ?u64 = null,

    pub fn merge(self: Budget, update: Budget) Budget {
        return .{
            .token_budget = update.token_budget orelse self.token_budget,
            .turn_budget = update.turn_budget orelse self.turn_budget,
            .wall_clock_budget_ms = update.wall_clock_budget_ms orelse self.wall_clock_budget_ms,
        };
    }
};

pub const BudgetReport = struct {
    token_budget: ?u64,
    turn_budget: ?u64,
    wall_clock_budget_ms: ?u64,
    remaining_tokens: ?u64,
    remaining_turns: ?u64,
    remaining_wall_clock_ms: ?u64,
    token_budget_reached: bool,
    turn_budget_reached: bool,
    wall_clock_budget_reached: bool,
    over_budget: bool,
};

pub const Snapshot = struct {
    id: u64,
    objective: []const u8,
    completion_criterion: ?[]const u8,
    status: Status,
    turns_used: u64,
    tokens_used: u64,
    wall_clock_ms: u64,
    budget: BudgetReport,
    terminal_reason: ?[]const u8,
};

pub const Completion = struct {
    turns_used: u64,
    tokens_used: u64,
    wall_clock_ms: u64,
    terminal_reason: ?[]const u8,
};

pub const GoalError = error{
    GoalAlreadyExists,
    GoalNotFound,
    ObjectiveEmpty,
    ObjectiveTooLong,
    StatusInvalid,
    NotResumable,
} || Allocator.Error;

pub fn errorMessage(err: GoalError) []const u8 {
    return switch (err) {
        error.GoalAlreadyExists => "A goal already exists; use replace to start a new one",
        error.GoalNotFound => "No current goal",
        error.ObjectiveEmpty => "Goal objective cannot be empty",
        error.ObjectiveTooLong => "Goal objective cannot exceed 4000 characters. Put long content in a file and reference the file path.",
        error.StatusInvalid => "Only an active goal can be paused",
        error.NotResumable => "Only paused or blocked goals can be resumed",
        error.OutOfMemory => "Out of memory",
    };
}

const Goal = struct {
    id: u64,
    objective: []u8,
    completion_criterion: ?[]u8,
    status: Status,
    turns_used: u64 = 0,
    tokens_used: u64 = 0,
    settled_wall_clock_ms: u64 = 0,
    live_started_ms: ?i64 = null,
    budget: Budget = .{},
    terminal_reason: ?[]u8 = null,

    fn deinit(self: Goal, alloc: Allocator) void {
        alloc.free(self.objective);
        if (self.completion_criterion) |text| alloc.free(text);
        if (self.terminal_reason) |text| alloc.free(text);
    }
};

pub const State = struct {
    goal: ?Goal = null,
    next_id: u64 = 1,

    pub fn deinit(self: *State, alloc: Allocator) void {
        if (self.goal) |goal| goal.deinit(alloc);
        self.goal = null;
    }

    pub fn currentId(self: *const State) ?u64 {
        const goal = self.goal orelse return null;
        return goal.id;
    }

    pub fn snapshot(self: *const State, now_ms: i64) ?Snapshot {
        const goal = self.goal orelse return null;
        return snapshotOf(goal, now_ms);
    }

    pub fn create(
        self: *State,
        alloc: Allocator,
        now_ms: i64,
        objective_text: []const u8,
        criterion_text: ?[]const u8,
        replace: bool,
    ) GoalError!Snapshot {
        const objective = try validateObjective(objective_text);
        if (self.goal != null) {
            if (!replace) return error.GoalAlreadyExists;
            self.clear(alloc);
        }
        const criterion = normalizeCompletionCriterion(criterion_text);
        const owned_objective = try alloc.dupe(u8, objective);
        errdefer alloc.free(owned_objective);
        const owned_criterion: ?[]u8 = if (criterion) |text| try alloc.dupe(u8, text) else null;
        errdefer if (owned_criterion) |text| alloc.free(text);
        const id = self.next_id;
        self.next_id += 1;
        self.goal = .{
            .id = id,
            .objective = owned_objective,
            .completion_criterion = owned_criterion,
            .status = .active,
            .live_started_ms = now_ms,
        };
        return snapshotOf(self.goal.?, now_ms);
    }

    pub fn pause(self: *State, alloc: Allocator, now_ms: i64, reason: ?[]const u8) GoalError!Snapshot {
        const goal = try self.requireGoal();
        if (goal.status == .paused) return snapshotOf(goal.*, now_ms);
        if (goal.status != .active) return error.StatusInvalid;
        try transition(alloc, goal, now_ms, .paused, reason);
        return snapshotOf(goal.*, now_ms);
    }

    pub fn resumeGoal(self: *State, alloc: Allocator, now_ms: i64) GoalError!Snapshot {
        const goal = try self.requireGoal();
        switch (goal.status) {
            .active => {},
            .paused, .blocked => try transition(alloc, goal, now_ms, .active, null),
            .complete => return error.NotResumable,
        }
        return snapshotOf(goal.*, now_ms);
    }

    pub fn markBlocked(self: *State, alloc: Allocator, now_ms: i64, reason: ?[]const u8) GoalError!?Snapshot {
        const goal = self.activeGoal() orelse return null;
        try transition(alloc, goal, now_ms, .blocked, reason);
        return snapshotOf(goal.*, now_ms);
    }

    pub fn markComplete(self: *State, alloc: Allocator, now_ms: i64, reason: ?[]const u8) GoalError!?Completion {
        const goal = self.activeGoal() orelse return null;
        settle(goal, now_ms);
        const completion = Completion{
            .turns_used = goal.turns_used,
            .tokens_used = goal.tokens_used,
            .wall_clock_ms = goal.settled_wall_clock_ms,
            .terminal_reason = reason,
        };
        self.clear(alloc);
        return completion;
    }

    pub fn setBudget(self: *State, alloc: Allocator, now_ms: i64, update: Budget) GoalError!Snapshot {
        const goal = try self.requireGoal();
        goal.budget = goal.budget.merge(update);
        try blockIfBudgetReached(alloc, goal, now_ms);
        return snapshotOf(goal.*, now_ms);
    }

    pub fn recordTurn(self: *State, now_ms: i64) ?Snapshot {
        const goal = self.activeGoal() orelse return null;
        goal.turns_used += 1;
        return snapshotOf(goal.*, now_ms);
    }

    pub fn recordTokens(self: *State, alloc: Allocator, now_ms: i64, delta: u64) GoalError!?Snapshot {
        const goal = self.activeGoal() orelse return null;
        goal.tokens_used += delta;
        try blockIfBudgetReached(alloc, goal, now_ms);
        return snapshotOf(goal.*, now_ms);
    }

    pub fn enforceWallClockBudget(self: *State, alloc: Allocator, now_ms: i64) GoalError!void {
        const goal = self.activeGoal() orelse return;
        try blockIfBudgetReached(alloc, goal, now_ms);
    }

    pub fn clear(self: *State, alloc: Allocator) void {
        if (self.goal) |goal| goal.deinit(alloc);
        self.goal = null;
    }

    fn requireGoal(self: *State) GoalError!*Goal {
        if (self.goal == null) return error.GoalNotFound;
        return &self.goal.?;
    }

    fn activeGoal(self: *State) ?*Goal {
        if (self.goal == null) return null;
        if (self.goal.?.status != .active) return null;
        return &self.goal.?;
    }
};

pub const View = struct {
    state: *State,
    alloc: Allocator,
    now_ms: i64,
};

fn snapshotOf(goal: Goal, now_ms: i64) Snapshot {
    const wall_clock_ms = liveWallClockMs(goal, now_ms);
    return .{
        .id = goal.id,
        .objective = goal.objective,
        .completion_criterion = goal.completion_criterion,
        .status = goal.status,
        .turns_used = goal.turns_used,
        .tokens_used = goal.tokens_used,
        .wall_clock_ms = wall_clock_ms,
        .budget = budgetReport(goal.budget, goal.turns_used, goal.tokens_used, wall_clock_ms),
        .terminal_reason = goal.terminal_reason,
    };
}

fn liveWallClockMs(goal: Goal, now_ms: i64) u64 {
    const started = goal.live_started_ms orelse return goal.settled_wall_clock_ms;
    return goal.settled_wall_clock_ms + @as(u64, @intCast(@max(0, now_ms - started)));
}

fn settle(goal: *Goal, now_ms: i64) void {
    if (goal.live_started_ms) |started| {
        goal.settled_wall_clock_ms += @as(u64, @intCast(@max(0, now_ms - started)));
        goal.live_started_ms = null;
    }
}

fn transition(alloc: Allocator, goal: *Goal, now_ms: i64, status: Status, reason: ?[]const u8) Allocator.Error!void {
    settle(goal, now_ms);
    const owned_reason: ?[]u8 = if (status == .active or reason == null) null else try alloc.dupe(u8, reason.?);
    if (goal.terminal_reason) |old| alloc.free(old);
    goal.terminal_reason = owned_reason;
    goal.status = status;
    if (status == .active) goal.live_started_ms = now_ms;
}

fn blockIfBudgetReached(alloc: Allocator, goal: *Goal, now_ms: i64) GoalError!void {
    if (goal.status != .active) return;
    const report = budgetReport(goal.budget, goal.turns_used, goal.tokens_used, liveWallClockMs(goal.*, now_ms));
    const reason = (try budgetBlockReason(alloc, goal.budget, report)) orelse return;
    defer alloc.free(reason);
    try transition(alloc, goal, now_ms, .blocked, reason);
}

fn budgetBlockReason(alloc: Allocator, budget: Budget, report: BudgetReport) Allocator.Error!?[]u8 {
    var parts: std.ArrayList(u8) = .empty;
    defer parts.deinit(alloc);
    if (report.turn_budget_reached) {
        try appendPart(alloc, &parts, try std.fmt.allocPrint(alloc, "turn budget {d}", .{budget.turn_budget.?}));
    }
    if (report.token_budget_reached) {
        try appendPart(alloc, &parts, try std.fmt.allocPrint(alloc, "token budget {d}", .{budget.token_budget.?}));
    }
    if (report.wall_clock_budget_reached) {
        try appendPart(alloc, &parts, try std.fmt.allocPrint(alloc, "wall-clock budget {d}ms", .{budget.wall_clock_budget_ms.?}));
    }
    if (parts.items.len == 0) return null;
    return try std.fmt.allocPrint(alloc, "{s}: {s}", .{ budget_block_prefix, parts.items });
}

fn appendPart(alloc: Allocator, parts: *std.ArrayList(u8), part: []u8) Allocator.Error!void {
    defer alloc.free(part);
    if (parts.items.len > 0) try parts.appendSlice(alloc, ", ");
    try parts.appendSlice(alloc, part);
}

fn budgetReport(budget: Budget, turns_used: u64, tokens_used: u64, wall_clock_ms: u64) BudgetReport {
    const token_reached = if (budget.token_budget) |limit| tokens_used >= limit else false;
    const turn_reached = if (budget.turn_budget) |limit| turns_used >= limit else false;
    const wall_reached = if (budget.wall_clock_budget_ms) |limit| wall_clock_ms >= limit else false;
    return .{
        .token_budget = budget.token_budget,
        .turn_budget = budget.turn_budget,
        .wall_clock_budget_ms = budget.wall_clock_budget_ms,
        .remaining_tokens = if (budget.token_budget) |limit| limit -| tokens_used else null,
        .remaining_turns = if (budget.turn_budget) |limit| limit -| turns_used else null,
        .remaining_wall_clock_ms = if (budget.wall_clock_budget_ms) |limit| limit -| wall_clock_ms else null,
        .token_budget_reached = token_reached,
        .turn_budget_reached = turn_reached,
        .wall_clock_budget_reached = wall_reached,
        .over_budget = token_reached or turn_reached or wall_reached,
    };
}

fn validateObjective(text: []const u8) GoalError![]const u8 {
    const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
    if (trimmed.len == 0) return error.ObjectiveEmpty;
    if (utf16Len(trimmed) > max_objective_units) return error.ObjectiveTooLong;
    return trimmed;
}

fn normalizeCompletionCriterion(text: ?[]const u8) ?[]const u8 {
    const raw = text orelse return null;
    const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
    if (trimmed.len == 0) return null;
    return truncateUtf16(trimmed, max_completion_criterion_units);
}

pub fn utf16Len(text: []const u8) usize {
    var units: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        const step = codepointStep(text, index);
        units += if (decodeAt(text, index, step) >= 0x10000) 2 else 1;
        index += step;
    }
    return units;
}

pub fn truncateUtf16(text: []const u8, max_units: usize) []const u8 {
    var units: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        const step = codepointStep(text, index);
        const width: usize = if (decodeAt(text, index, step) >= 0x10000) 2 else 1;
        if (units + width > max_units) break;
        units += width;
        index += step;
    }
    return text[0..index];
}

fn codepointStep(text: []const u8, index: usize) usize {
    const width = std.unicode.utf8ByteSequenceLength(text[index]) catch return 1;
    if (index + width > text.len) return 1;
    return width;
}

fn decodeAt(text: []const u8, index: usize, step: usize) u21 {
    if (step == 1) return text[index];
    return std.unicode.utf8Decode(text[index .. index + step]) catch text[index];
}

test "CreateGoal trims the objective and rejects an empty one" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    _ = try state.create(alloc, 0, "  ship the parser  ", null, false);
    try std.testing.expectEqualStrings("ship the parser", state.snapshot(0).?.objective);
    var empty: State = .{};
    defer empty.deinit(alloc);
    try std.testing.expectError(error.ObjectiveEmpty, empty.create(alloc, 0, " \n\t ", null, false));
}

test "CreateGoal refuses a second goal unless replace is set" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    const first = try state.create(alloc, 0, "first", null, false);
    try std.testing.expectEqualStrings("first", first.objective);
    try std.testing.expectError(error.GoalAlreadyExists, state.create(alloc, 0, "second", null, false));
    const replaced = try state.create(alloc, 0, "second", null, true);
    try std.testing.expectEqualStrings("second", replaced.objective);
    try std.testing.expect(replaced.id != first.id);
}

test "CreateGoal rejects an objective over 4000 UTF-16 units and counts astral characters as two" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    const long = try alloc.alloc(u8, max_objective_units + 1);
    defer alloc.free(long);
    @memset(long, 'a');
    try std.testing.expectError(error.ObjectiveTooLong, state.create(alloc, 0, long, null, false));
    const at_limit = long[0..max_objective_units];
    _ = try state.create(alloc, 0, at_limit, null, false);
    var astral_text: std.ArrayList(u8) = .empty;
    defer astral_text.deinit(alloc);
    for (0..2001) |_| try astral_text.appendSlice(alloc, "\u{1F600}");
    try std.testing.expectEqual(@as(usize, 4002), utf16Len(astral_text.items));
    try std.testing.expectError(error.ObjectiveTooLong, state.create(alloc, 0, astral_text.items, null, true));
}

test "CreateGoal drops a blank completion criterion and truncates a long one" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    const blank = try state.create(alloc, 0, "goal", "   ", false);
    try std.testing.expect(blank.completion_criterion == null);
    _ = try state.create(alloc, 0, "goal", "tests pass", true);
    try std.testing.expectEqualStrings("tests pass", state.snapshot(0).?.completion_criterion.?);
    const long = try alloc.alloc(u8, max_completion_criterion_units + 10);
    defer alloc.free(long);
    @memset(long, 'x');
    _ = try state.create(alloc, 0, "goal", long, true);
    try std.testing.expectEqual(max_completion_criterion_units, state.snapshot(0).?.completion_criterion.?.len);
}

test "MarkComplete returns the final stats and clears the goal" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    _ = try state.create(alloc, 0, "goal", null, false);
    _ = state.recordTurn(10);
    _ = try state.recordTokens(alloc, 20, 1500);
    const done = (try state.markComplete(alloc, 2500, null)).?;
    try std.testing.expectEqual(@as(u64, 1), done.turns_used);
    try std.testing.expectEqual(@as(u64, 1500), done.tokens_used);
    try std.testing.expectEqual(@as(u64, 2500), done.wall_clock_ms);
    try std.testing.expect(state.snapshot(3000) == null);
    try std.testing.expect((try state.markComplete(alloc, 3000, null)) == null);
}

test "MarkBlocked keeps the goal blocked with its reason and resume clears it" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    _ = try state.create(alloc, 0, "goal", null, false);
    const blocked = (try state.markBlocked(alloc, 100, "needs credentials")).?;
    try std.testing.expectEqual(Status.blocked, blocked.status);
    try std.testing.expectEqualStrings("needs credentials", blocked.terminal_reason.?);
    try std.testing.expect((try state.markBlocked(alloc, 200, "again")) == null);
    const resumed = try state.resumeGoal(alloc, 300);
    try std.testing.expectEqual(Status.active, resumed.status);
    try std.testing.expect(resumed.terminal_reason == null);
}

test "Resume reports a missing goal and leaves an active goal active" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    try std.testing.expectError(error.GoalNotFound, state.resumeGoal(alloc, 0));
    _ = try state.create(alloc, 0, "goal", null, false);
    const active = try state.resumeGoal(alloc, 0);
    try std.testing.expectEqual(Status.active, active.status);
}

test "Pause moves an active goal to paused and rejects a finished one" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    _ = try state.create(alloc, 0, "goal", null, false);
    const paused = try state.pause(alloc, 50, "user asked");
    try std.testing.expectEqual(Status.paused, paused.status);
    const again = try state.pause(alloc, 60, null);
    try std.testing.expectEqual(Status.paused, again.status);
    _ = try state.resumeGoal(alloc, 65);
    _ = (try state.markComplete(alloc, 70, null)).?;
    try std.testing.expectError(error.GoalNotFound, state.pause(alloc, 80, null));
}

test "SetBudget blocks an active goal that already reached the turn budget" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    _ = try state.create(alloc, 0, "goal", null, false);
    _ = state.recordTurn(1);
    _ = state.recordTurn(2);
    const set = try state.setBudget(alloc, 3, .{ .turn_budget = 2 });
    try std.testing.expectEqual(Status.blocked, set.status);
    try std.testing.expect(set.budget.turn_budget_reached);
    try std.testing.expect(set.budget.over_budget);
    try std.testing.expectEqualStrings("Blocked after goal budget reached: turn budget 2", set.terminal_reason.?);
}

test "RecordTokens blocks the goal when the token budget is reached" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    _ = try state.create(alloc, 0, "goal", null, false);
    _ = try state.setBudget(alloc, 0, .{ .token_budget = 1000 });
    const under = (try state.recordTokens(alloc, 0, 400)).?;
    try std.testing.expectEqual(Status.active, under.status);
    try std.testing.expectEqual(@as(u64, 600), under.budget.remaining_tokens.?);
    const over = (try state.recordTokens(alloc, 0, 700)).?;
    try std.testing.expectEqual(Status.blocked, over.status);
    try std.testing.expectEqualStrings("Blocked after goal budget reached: token budget 1000", over.terminal_reason.?);
}

test "Wall clock budget blocks the goal once live time reaches it" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    _ = try state.create(alloc, 0, "goal", null, false);
    _ = try state.setBudget(alloc, 0, .{ .wall_clock_budget_ms = 5000 });
    try state.enforceWallClockBudget(alloc, 4999);
    try std.testing.expectEqual(Status.active, state.snapshot(4999).?.status);
    try state.enforceWallClockBudget(alloc, 5000);
    try std.testing.expectEqual(Status.blocked, state.snapshot(5000).?.status);
    try std.testing.expectEqualStrings("Blocked after goal budget reached: wall-clock budget 5000ms", state.snapshot(5000).?.terminal_reason.?);
}

test "Snapshot reports remaining budgets and only counts wall clock while active" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    _ = try state.create(alloc, 0, "goal", null, false);
    _ = try state.setBudget(alloc, 0, .{ .turn_budget = 10, .wall_clock_budget_ms = 60_000 });
    _ = try state.pause(alloc, 1000, null);
    const paused_snap = state.snapshot(9000).?;
    try std.testing.expectEqual(@as(u64, 1000), paused_snap.wall_clock_ms);
    try std.testing.expectEqual(@as(u64, 10), paused_snap.budget.remaining_turns.?);
    try std.testing.expectEqual(@as(u64, 59_000), paused_snap.budget.remaining_wall_clock_ms.?);
    try std.testing.expect(!paused_snap.budget.over_budget);
}

test "truncateUtf16 never splits a code point" {
    const text = "ab\u{1F600}cd";
    try std.testing.expectEqualStrings("ab", truncateUtf16(text, 3));
    try std.testing.expectEqualStrings("ab\u{1F600}", truncateUtf16(text, 4));
}
