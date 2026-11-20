const std = @import("std");

pub const Timing = struct {
    ttl_ms: i64,
    cap_ms: i64,

    pub const claude: Timing = .{ .ttl_ms = 5 * std.time.ms_per_min, .cap_ms = 30 * std.time.ms_per_min };

    pub fn interval(self: Timing) i64 {
        return self.ttl_ms - @divTrunc(self.ttl_ms, 10);
    }

    pub fn late(self: Timing) i64 {
        return @divTrunc(self.ttl_ms - self.interval(), 2);
    }
};

pub const Stop = enum {
    disarmed,
    cap,
    late,
    failed,
    missed,
};

pub const Outcome = enum { read, missed, failed };

pub const State = struct {
    armed: bool = false,
    generation: u64 = 0,
    request_started_ms: i64 = 0,
    last_touch_ms: i64 = 0,
    pings: u32 = 0,
    in_flight: ?u64 = null,
    in_flight_started_ms: i64 = 0,
    stopped: ?Stop = null,
};

pub const Event = union(enum) {
    armed: struct { now_ms: i64, started_ms: i64 },
    disarmed: struct { now_ms: i64 },
    woke: struct { now_ms: i64 },
    answered: struct { now_ms: i64, generation: u64, outcome: Outcome },
};

pub const Plan = union(enum) {
    idle,
    wait_until: i64,
    wait_for_answer,
    ping: u64,
    stopped: Stop,
};

pub fn step(state: *State, timing: Timing, event: Event) Plan {
    switch (event) {
        .armed => |armed| {
            state.generation +%= 1;
            state.armed = true;
            state.request_started_ms = armed.started_ms;
            state.last_touch_ms = armed.started_ms;
            state.pings = 0;
            state.stopped = null;

            if (armed.now_ms > due(state, timing) + timing.late()) return stop(state, .late);
            return afterTouch(state, timing);
        },
        .disarmed => {
            state.generation +%= 1;
            if (!state.armed) return next(state, timing);
            return stop(state, .disarmed);
        },
        .woke => |woke| {
            if (!state.armed or state.in_flight != null) return next(state, timing);
            const due_ms = due(state, timing);
            if (woke.now_ms < due_ms) return .{ .wait_until = due_ms };
            if (woke.now_ms > due_ms + timing.late()) return stop(state, .late);
            state.in_flight = state.generation;
            state.in_flight_started_ms = woke.now_ms;
            state.pings +|= 1;
            return .{ .ping = state.generation };
        },
        .answered => |answered| {
            if (state.in_flight != answered.generation) return next(state, timing);
            state.in_flight = null;

            if (!state.armed or answered.generation != state.generation) return next(state, timing);
            return switch (answered.outcome) {
                .read => read: {
                    state.last_touch_ms = state.in_flight_started_ms;
                    break :read afterTouch(state, timing);
                },
                .missed => stop(state, .missed),
                .failed => stop(state, .failed),
            };
        },
    }
}

fn due(state: *const State, timing: Timing) i64 {
    return state.last_touch_ms + timing.interval();
}

fn afterTouch(state: *State, timing: Timing) Plan {
    if (due(state, timing) > state.request_started_ms + timing.cap_ms) return stop(state, .cap);
    return next(state, timing);
}

fn next(state: *const State, timing: Timing) Plan {
    if (state.in_flight != null) return .wait_for_answer;
    if (!state.armed) return .idle;
    return .{ .wait_until = due(state, timing) };
}

fn stop(state: *State, reason: Stop) Plan {
    state.armed = false;
    state.stopped = reason;
    return .{ .stopped = reason };
}

pub const Candidate = struct {
    gateway_with_direct_credential: bool,
    model: []const u8,
    root_turn: bool,
    prompt_caching: bool,
    reasoning: bool,
    model_has_efforts: bool,
};

pub const Skip = enum { not_claude, not_gateway, subagent, no_prompt_caching, budget_thinking };

pub fn skipReason(candidate: Candidate) ?Skip {
    if (!std.mem.startsWith(u8, candidate.model, "anthropic/")) return .not_claude;
    if (!candidate.gateway_with_direct_credential) return .not_gateway;
    if (!candidate.root_turn) return .subagent;
    if (!candidate.prompt_caching) return .no_prompt_caching;
    if (candidate.reasoning and !candidate.model_has_efforts) return .budget_thinking;
    return null;
}

const testing = std.testing;
const claude = Timing.claude;
const min = std.time.ms_per_min;

test "the five-minute lifetime pings at 4.5 minutes and trusts a wake up to 15 seconds late" {
    try testing.expectEqual(@as(i64, 270_000), claude.interval());
    try testing.expectEqual(@as(i64, 15_000), claude.late());
}

test "an armed request is pinged six times, then warming stops at the 30-minute cap" {
    var state: State = .{};
    try testing.expectEqual(Plan{ .wait_until = 270_000 }, step(&state, claude, .{ .armed = .{ .now_ms = 2_000, .started_ms = 0 } }));
    var pinged: u32 = 0;
    var now: i64 = 270_000;
    while (true) : (now += claude.interval()) {
        const plan = step(&state, claude, .{ .woke = .{ .now_ms = now } });
        try testing.expectEqual(Plan{ .ping = state.generation }, plan);
        pinged += 1;
        const after = step(&state, claude, .{ .answered = .{ .now_ms = now + 800, .generation = state.generation, .outcome = .read } });
        if (after == .stopped) {
            try testing.expectEqual(Stop.cap, after.stopped);
            break;
        }
        try testing.expectEqual(Plan{ .wait_until = now + claude.interval() }, after);
    }
    try testing.expectEqual(@as(u32, 6), pinged);

    try testing.expectEqual(@as(i64, 27 * min), now);
    try testing.expect(!state.armed);
}

test "a wake after the machine slept past the margin stops instead of paying a write" {
    var state: State = .{};
    _ = step(&state, claude, .{ .armed = .{ .now_ms = 1_000, .started_ms = 0 } });
    try testing.expectEqual(Plan{ .ping = state.generation }, step(&state, claude, .{ .woke = .{ .now_ms = 285_000 } }));
    _ = step(&state, claude, .{ .answered = .{ .now_ms = 286_000, .generation = state.generation, .outcome = .read } });
    try testing.expectEqual(Plan{ .stopped = .late }, step(&state, claude, .{ .woke = .{ .now_ms = 285_000 + 270_000 + 15_001 } }));
}

test "an early wake waits for the planned time" {
    var state: State = .{};
    _ = step(&state, claude, .{ .armed = .{ .now_ms = 1_000, .started_ms = 0 } });
    try testing.expectEqual(Plan{ .wait_until = 270_000 }, step(&state, claude, .{ .woke = .{ .now_ms = 100_000 } }));
}

test "a reply that streamed past the margin is not armed" {
    var state: State = .{};
    try testing.expectEqual(Plan{ .stopped = .late }, step(&state, claude, .{ .armed = .{ .now_ms = 285_001, .started_ms = 0 } }));
    var close: State = .{};
    try testing.expectEqual(Plan{ .wait_until = 270_000 }, step(&close, claude, .{ .armed = .{ .now_ms = 285_000, .started_ms = 0 } }));
}

test "a disarm ends warming and makes the ping on the wire stale" {
    var state: State = .{};
    _ = step(&state, claude, .{ .armed = .{ .now_ms = 1_000, .started_ms = 0 } });
    const generation = step(&state, claude, .{ .woke = .{ .now_ms = 270_000 } }).ping;
    try testing.expectEqual(Plan{ .stopped = .disarmed }, step(&state, claude, .{ .disarmed = .{ .now_ms = 270_100 } }));

    try testing.expectEqual(Plan.wait_for_answer, step(&state, claude, .{ .armed = .{ .now_ms = 272_000, .started_ms = 270_100 } }));

    try testing.expectEqual(Plan{ .wait_until = 270_100 + 270_000 }, step(&state, claude, .{ .answered = .{ .now_ms = 272_500, .generation = generation, .outcome = .failed } }));
    try testing.expect(state.armed);
    try testing.expectEqual(@as(?u64, null), state.in_flight);
}

test "a failed or missed ping stops warming" {
    inline for (.{ .{ Outcome.failed, Stop.failed }, .{ Outcome.missed, Stop.missed } }) |case| {
        var state: State = .{};
        _ = step(&state, claude, .{ .armed = .{ .now_ms = 1_000, .started_ms = 0 } });
        const generation = step(&state, claude, .{ .woke = .{ .now_ms = 270_000 } }).ping;
        try testing.expectEqual(Plan{ .stopped = case[1] }, step(&state, claude, .{ .answered = .{ .now_ms = 271_000, .generation = generation, .outcome = case[0] } }));
        try testing.expect(!state.armed);
    }
}

test "the timer never starts a second ping while one is on the wire" {
    var state: State = .{};
    _ = step(&state, claude, .{ .armed = .{ .now_ms = 1_000, .started_ms = 0 } });
    _ = step(&state, claude, .{ .woke = .{ .now_ms = 270_000 } });
    try testing.expectEqual(Plan.wait_for_answer, step(&state, claude, .{ .woke = .{ .now_ms = 271_000 } }));
    try testing.expectEqual(@as(u32, 1), state.pings);
}

test "nothing pings without an arm" {
    var state: State = .{};
    try testing.expectEqual(Plan.idle, step(&state, claude, .{ .woke = .{ .now_ms = 270_000 } }));
    try testing.expectEqual(Plan.idle, step(&state, claude, .{ .disarmed = .{ .now_ms = 270_000 } }));
}

test "only Claude requests through AI Gateway with fx's credential are kept warm" {
    const base: Candidate = .{
        .gateway_with_direct_credential = true,
        .model = "anthropic/claude-opus-5.5",
        .root_turn = true,
        .prompt_caching = true,
        .reasoning = true,
        .model_has_efforts = true,
    };
    try testing.expectEqual(@as(?Skip, null), skipReason(base));
    var other = base;
    other.model = "openai/gpt-6.1";
    try testing.expectEqual(@as(?Skip, .not_claude), skipReason(other));
    other = base;
    other.gateway_with_direct_credential = false;
    try testing.expectEqual(@as(?Skip, .not_gateway), skipReason(other));
    other = base;
    other.root_turn = false;
    try testing.expectEqual(@as(?Skip, .subagent), skipReason(other));
    other = base;
    other.prompt_caching = false;
    try testing.expectEqual(@as(?Skip, .no_prompt_caching), skipReason(other));

    other = base;
    other.model_has_efforts = false;
    try testing.expectEqual(@as(?Skip, .budget_thinking), skipReason(other));
    other.reasoning = false;
    try testing.expectEqual(@as(?Skip, null), skipReason(other));
}
