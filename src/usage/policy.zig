const std = @import("std");
const report = @import("report.zig");

pub const floor_ms: i64 = 60 * std.time.ms_per_s;
pub const timer_ms: i64 = 15 * std.time.ms_per_min;

pub const Trigger = enum {
    open,
    manual,
    timer,
};

pub const State = struct {
    in_flight: bool = false,
    last_start_ms: ?i64 = null,
    failed_at_ms: ?i64 = null,
};

fn since(t: ?i64, n: i64, now_ms: i64) bool {
    const at = t orelse return true;
    return now_ms < at or now_ms - at >= n;
}

fn floorClear(state: State, now_ms: i64) bool {
    return !state.in_flight and
        since(state.last_start_ms, floor_ms, now_ms) and
        since(state.failed_at_ms, floor_ms, now_ms);
}

pub fn due(trigger: Trigger, open: bool, state: State, now_ms: i64) bool {
    return switch (trigger) {
        .open => floorClear(state, now_ms),
        .manual => open and !state.in_flight,
        .timer => open and floorClear(state, now_ms) and
            state.last_start_ms != null and since(state.last_start_ms, timer_ms, now_ms),
    };
}

pub const Plan = struct {
    day: i64,
    finished: bool,
    budget: bool,

    pub fn todayRange(self: Plan) [2]i64 {
        return .{ self.day, self.day };
    }

    pub fn weekRange(self: Plan) [2]i64 {
        return .{ self.day - 6, self.day - 1 };
    }

    pub fn monthRange(self: Plan) ?[2]i64 {
        const first = report.monthStart(self.day);
        if (first == self.day) return null;
        return .{ first, self.day - 1 };
    }
};

pub fn plan(scope: report.Scope, cached_finished_day: ?i64, now_ms: i64) Plan {
    const day = report.utcDay(now_ms);
    return .{
        .day = day,
        .finished = scope.readsReports() and (cached_finished_day == null or cached_finished_day.? != day),
        .budget = scope == .member,
    };
}

const testing = std.testing;

test "opening fetches unless the floor or a recent failure holds it" {
    const t0: i64 = 1_000_000;
    try testing.expect(due(.open, true, .{}, t0));
    const started: State = .{ .last_start_ms = t0 };
    try testing.expect(!due(.open, true, started, t0 + floor_ms - 1));
    try testing.expect(due(.open, true, started, t0 + floor_ms));
    try testing.expect(!due(.open, true, .{ .failed_at_ms = t0 }, t0 + 1));
    try testing.expect(!due(.open, true, .{ .in_flight = true }, t0));
}

test "r needs the dashboard open and nothing in flight, never the floor" {
    const t0: i64 = 1_000_000;
    try testing.expect(!due(.manual, false, .{}, t0));
    try testing.expect(due(.manual, true, .{}, t0));
    try testing.expect(due(.manual, true, .{ .last_start_ms = t0 }, t0 + 1));
    try testing.expect(due(.manual, true, .{ .failed_at_ms = t0 }, t0 + 1));
    try testing.expect(!due(.manual, true, .{ .in_flight = true }, t0));
}

test "a clock corrected backward does not hold fetches until it catches up" {
    const t0: i64 = 1_000_000;
    const back = t0 - std.time.ms_per_hour;
    try testing.expect(due(.open, false, .{ .last_start_ms = t0 }, back));
    try testing.expect(due(.manual, true, .{ .failed_at_ms = t0 }, back));
    try testing.expect(due(.timer, true, .{ .last_start_ms = t0 }, back));
    try testing.expect(!due(.open, false, .{ .last_start_ms = back }, back + 1));
}

test "the timer fires every 15 minutes while open, never while closed" {
    const t0: i64 = 1_000_000;
    const started: State = .{ .last_start_ms = t0 };
    try testing.expect(!due(.timer, true, .{}, t0));
    try testing.expect(!due(.timer, true, started, t0 + timer_ms - 1));
    try testing.expect(due(.timer, true, started, t0 + timer_ms));
    try testing.expect(!due(.timer, false, started, t0 + timer_ms));
}

test "finished days are read once per UTC day" {
    const now: i64 = 1_791_676_800_000 + 3 * std.time.ms_per_hour;
    const today = report.utcDay(now);
    const first = plan(.member, null, now);
    try testing.expect(first.finished and first.budget);
    try testing.expectEqual([2]i64{ today - 6, today - 1 }, first.weekRange());
    try testing.expectEqual([2]i64{ today - 10, today - 1 }, first.monthRange().?);
    try testing.expect(plan(.member, null, now - 10 * std.time.ms_per_day).monthRange() == null);
    try testing.expect(!plan(.member, today, now).finished);
    try testing.expect(plan(.api_key, today - 1, now).finished);
    try testing.expect(!plan(.api_key, today, now).budget);
    const codex_plan = plan(.codex, null, now);
    try testing.expect(!codex_plan.finished and !codex_plan.budget);
    const grok_plan = plan(.grok, null, now);
    try testing.expect(!grok_plan.finished and !grok_plan.budget);
}
