const std = @import("std");
const trace = @import("../io/trace.zig");

pub const Phase = enum { idle, connecting, ready, backoff, failed };
pub const Handle = u32;
pub const max_calls = 24;

pub const failure_streak_cap: u8 = 31;

pub const Config = struct {
    max_attempts: ?u8 = null,
    stable_ms: u32 = 60_000,
    reconnect_initial_ms: u32 = 5_000,
    reconnect_cap_ms: u32 = 300_000,

    fn gaveUp(c: Config, attempts: u8) bool {
        const limit = c.max_attempts orelse return false;
        return attempts >= limit;
    }

    pub fn reconnectDelay(c: Config, failure_streak: u8) u32 {
        const doubled = @as(u64, c.reconnect_initial_ms) << @intCast(@min(failure_streak, failure_streak_cap));
        return @intCast(@min(doubled, c.reconnect_cap_ms));
    }
};

pub fn jitteredDelay(delay_ms: u32, entropy: u32) u32 {
    const half = delay_ms / 2;
    const spread = (@as(u64, delay_ms - half) * entropy) >> 32;
    return half + @as(u32, @intCast(spread));
}

pub const Event = union(enum) {
    asked: struct { call: Handle, allowed: bool },
    need,
    cancel: Handle,
    drop: struct { keep: bool },
    up,
    down,
    broken,
    backoff_over,
    stable,
    answered: Handle,
};

pub const End = enum { denied, failed, cancelled, lost };

pub const Effect = union(enum) {
    connect,
    send: Handle,
    end: struct { call: Handle, end: End },
    list,
    refuse_need,
    arm_backoff: u32,
    arm_stable: u32,
    teardown,
};

pub const Projection = struct {
    phase: Phase,
    attempts: u8,
    need: bool,
    waiting: u32,
    sent: u32,
    state: u8,
    retry: bool,
};

pub const Output = struct {
    effect_buffer: [max_calls + 4]Effect = undefined,
    effect_count: usize = 0,
    action: []const u8 = "",
    ignored: bool = false,
    n: u32 = 0,
    mid: ?Projection = null,

    pub fn effects(out: *const Output) []const Effect {
        return out.effect_buffer[0..out.effect_count];
    }

    fn emit(out: *Output, effect: Effect) void {
        out.effect_buffer[out.effect_count] = effect;
        out.effect_count += 1;
    }
};

pub const Call = struct {
    used: bool = false,
    handle: Handle = 0,
    n: u32 = 0,
    sent: bool = false,
};

pub const Gate = struct {
    config: Config,
    phase: Phase = .idle,
    attempts: u8 = 0,
    need: bool = false,
    retry: bool = false,
    calls: [max_calls]Call = @splat(.{}),
    last: u32 = 0,

    pub fn init(config: Config) Gate {
        return .{ .config = config };
    }

    pub fn step(s: *Gate, event: Event, out: *Output) error{TooManyCalls}!void {
        switch (event) {
            .asked => |a| {
                const open = for (&s.calls) |*c| {
                    if (!c.used) break c;
                } else if (a.allowed and s.phase != .failed) return error.TooManyCalls else null;
                s.last += 1;
                out.action = "ask";
                out.n = s.last;
                if (!a.allowed) return out.emit(.{ .end = .{ .call = a.call, .end = .denied } });
                if (s.phase == .failed) return out.emit(.{ .end = .{ .call = a.call, .end = .failed } });
                open.?.* = .{ .used = true, .handle = a.call, .n = s.last, .sent = s.phase == .ready };
                if (s.phase == .ready) out.emit(.{ .send = a.call }) else s.connect(out);
            },
            .need => {
                out.action = "need";
                switch (s.phase) {
                    .ready => return ignoreWith(out, .list),
                    .failed => return ignoreWith(out, .refuse_need),
                    else => if (s.need) return ignore(out),
                }
                s.need = true;
                s.connect(out);
            },
            .cancel => |handle| {
                out.action = "cancel";
                const c = s.find(handle) orelse return ignore(out);
                out.n = c.n;
                if (c.sent) return ignore(out);
                out.emit(.{ .end = .{ .call = handle, .end = .cancelled } });
                c.* = .{};
            },
            .drop => |d| {
                out.action = "drop";
                out.emit(.teardown);
                for (&s.calls) |*c| if (c.used and (c.sent or !d.keep)) {
                    out.emit(.{ .end = .{ .call = c.handle, .end = .cancelled } });
                    c.* = .{};
                };
                s.phase = .idle;
                s.attempts = 0;

                if (s.need and !d.keep) out.emit(.refuse_need);
                s.need = s.need and d.keep;
                s.retry = false;
                s.connect(out);
            },
            .up => {
                out.action = "up";
                if (s.phase != .connecting) return ignore(out);
                s.phase = .ready;
                s.retry = false;
                if (s.config.max_attempts == null) s.attempts = 0;
                if (s.need) out.emit(.list);
                s.need = false;
                for (&s.calls) |*c| if (c.used and !c.sent) {
                    c.sent = true;
                    out.emit(.{ .send = c.handle });
                };

                out.emit(.{ .arm_stable = s.config.stable_ms });
            },
            .down => {
                out.action = "down";
                if (s.phase != .connecting and s.phase != .ready) return ignore(out);
                const gave_up = s.config.gaveUp(s.attempts);
                s.retry = !gave_up;

                for (&s.calls) |*c| if (c.used) {
                    out.emit(.{ .end = .{ .call = c.handle, .end = if (c.sent) .lost else .failed } });
                    c.* = .{};
                };
                if (gave_up) {
                    s.phase = .failed;
                    if (s.need) out.emit(.refuse_need);
                    s.need = false;
                } else {
                    s.phase = .backoff;
                    out.emit(.{ .arm_backoff = s.config.reconnectDelay(s.attempts -| 1) });
                }
            },
            .broken => {
                out.action = "broken";
                if (s.phase != .connecting and s.phase != .ready) return ignore(out);
                s.retry = false;
                for (&s.calls) |*c| if (c.used) {
                    out.emit(.{ .end = .{ .call = c.handle, .end = if (c.sent) .lost else .failed } });
                    c.* = .{};
                };
                s.phase = .failed;
                if (s.need) out.emit(.refuse_need);
                s.need = false;
            },
            .backoff_over => {
                out.action = "backoff_over";
                if (s.phase != .backoff) return ignore(out);
                s.phase = .idle;
                s.connect(out);
            },
            .stable => {
                out.action = "stable";
                if (s.phase != .ready or s.attempts == 0) return ignore(out);
                s.attempts = 0;
            },
            .answered => |handle| {
                out.action = "answer";
                const c = s.find(handle) orelse return ignore(out);
                out.n = c.n;
                if (!c.sent) return ignore(out);
                c.* = .{};
            },
        }
    }

    fn connect(s: *Gate, out: *Output) void {
        if (s.phase != .idle or !(s.demand() or s.retry) or s.config.gaveUp(s.attempts)) return;
        out.mid = s.project(out.n);
        s.phase = .connecting;
        s.attempts = @min(s.attempts +| 1, s.config.max_attempts orelse failure_streak_cap + 1);
        out.emit(.connect);
    }

    pub fn demand(s: *const Gate) bool {
        if (s.need) return true;
        for (s.calls) |c| if (c.used and !c.sent) return true;
        return false;
    }

    fn find(s: *Gate, handle: Handle) ?*Call {
        for (&s.calls) |*c| if (c.used and c.handle == handle) return c;
        return null;
    }

    pub fn project(s: *const Gate, n: u32) Projection {
        var p: Projection = .{ .phase = s.phase, .attempts = s.attempts, .need = s.need, .waiting = 0, .sent = 0, .state = if (n == 0) 0 else 3, .retry = s.retry };
        for (s.calls) |c| if (c.used) {
            if (c.sent) p.sent += 1 else p.waiting += 1;
            if (c.n == n) p.state = if (c.sent) 2 else 1;
        };
        return p;
    }

    fn ignore(out: *Output) void {
        out.ignored = true;
    }

    fn ignoreWith(out: *Output, effect: Effect) void {
        out.ignored = true;
        out.emit(effect);
    }
};

pub fn writeTrace(writer: *trace.Writer, instance: []const u8, s: *const Gate, event: Event, out: *const Output) std.Io.Writer.Error!void {
    if (out.action.len == 0) return;
    if (out.mid) |mid| {
        try record(writer, instance, s, event, out, out.action, mid);
        return record(writer, instance, s, event, out, "connect", s.project(out.n));
    }
    try record(writer, instance, s, event, out, out.action, s.project(out.n));
}

fn record(writer: *trace.Writer, instance: []const u8, s: *const Gate, event: Event, out: *const Output, action: []const u8, p: Projection) std.Io.Writer.Error!void {
    try writer.write(.{
        .machine = "engine",
        .instance = instance,
        .event = action,
        .from = "",
        .to = "",
        .data = &.{
            .{ .name = "ignored", .value = .{ .boolean = out.ignored } },

            .{ .name = "n", .value = .{ .int = @min(out.n, 1 << 30) } },
            .{ .name = "allowed", .value = .{ .boolean = event == .asked and event.asked.allowed } },
            .{ .name = "keep", .value = .{ .boolean = event == .drop and event.drop.keep } },
            .{ .name = "phase", .value = .{ .int = @backingInt(p.phase) } },
            .{ .name = "attempts", .value = .{ .int = p.attempts } },
            .{ .name = "need", .value = .{ .boolean = p.need } },
            .{ .name = "waiting", .value = .{ .int = p.waiting } },
            .{ .name = "sent", .value = .{ .int = p.sent } },
            .{ .name = "state", .value = .{ .int = p.state } },
            .{ .name = "retry", .value = .{ .boolean = p.retry } },
            .{ .name = "max", .value = .{ .int = s.config.max_attempts orelse 0 } },
        },
    });
}

const testing = std.testing;

const World = struct {
    const max_n = 512;
    allowed: [max_n]bool = @splat(false),
    went_out: [max_n]bool = @splat(false),
    downs: u32 = 0,
    broken: bool = false,

    fn check(w: *World, s: *const Gate, before: *const Gate, event: Event, out: *const Output) !void {
        if (event == .asked and out.n > 0 and out.n < max_n) w.allowed[out.n] = event.asked.allowed;
        for (out.effects()) |effect| switch (effect) {
            .send => |h| {
                const n = for (s.calls) |c| {
                    if (c.used and c.handle == h) break c.n;
                } else unreachable;
                try testing.expect(w.allowed[n]);
                try testing.expectEqual(Phase.ready, s.phase);
                w.went_out[n] = true;
            },

            .connect => {
                const mid = out.mid.?;
                try testing.expect(mid.phase == .idle and (mid.need or mid.waiting > 0 or mid.retry));
                try testing.expect(mid.attempts < s.config.max_attempts.?);
            },
            .end => |e| if (e.end == .denied) try testing.expect(event == .asked and !event.asked.allowed),
            .list => try testing.expect(s.phase == .ready),
            .refuse_need => try testing.expect(s.phase == .failed or (event == .drop and !event.drop.keep)),
            else => {},
        };
        try testing.expect(s.attempts <= s.config.max_attempts.?);
        if (!out.ignored) switch (event) {
            .down => w.downs += 1,
            .broken => w.broken = true,
            .stable => w.downs = 0,
            .drop => {
                w.downs = 0;
                w.broken = false;
            },
            else => {},
        };

        try testing.expect(w.downs <= @as(u32, s.config.max_attempts.?) + 1);
        if (s.retry) try testing.expect(w.downs > 0 and (s.phase == .backoff or s.phase == .idle or s.phase == .connecting));

        if (s.phase == .failed and !w.broken) try testing.expectEqual(s.config.max_attempts.?, s.attempts);
        if (s.phase != .failed) try testing.expect(!w.broken);

        const p = s.project(0);
        if (p.sent > 0) try testing.expectEqual(Phase.ready, s.phase);
        if (s.phase == .failed or s.phase == .ready) try testing.expect(!s.need and p.waiting == 0);

        if ((before.phase == .connecting or before.phase == .ready) and (s.phase == .backoff or s.phase == .failed)) try testing.expectEqual(@as(u32, 0), p.waiting);

        try testing.expect(!(s.phase == .idle and (s.demand() or s.retry) and s.attempts < s.config.max_attempts.?));

        if (out.ignored and out.mid == null) try testing.expectEqualDeep(before.project(0), s.project(0));
        switch (event) {
            .up => if (before.phase == .connecting and before.need) {
                var listed = false;
                for (out.effects()) |effect| listed = listed or effect == .list;
                try testing.expect(listed);
            },

            .answered, .cancel => |h| for (before.calls) |c| if (c.used and c.handle == h and c.sent == (event == .cancel)) {
                try testing.expect(out.ignored);
            },

            .drop => |d| {
                try testing.expect(s.attempts <= 1);
                if (before.need and !d.keep) {
                    var refused = false;
                    for (out.effects()) |effect| refused = refused or effect == .refuse_need;
                    try testing.expect(refused);
                }
            },
            else => {},
        }
    }
};

const alphabet = [_]Event{
    .{ .asked = .{ .call = 1, .allowed = true } },
    .{ .asked = .{ .call = 2, .allowed = true } },
    .{ .asked = .{ .call = 3, .allowed = false } },
    .need,
    .{ .cancel = 1 },
    .{ .drop = .{ .keep = true } },
    .{ .drop = .{ .keep = false } },
    .up,
    .down,
    .broken,
    .backoff_over,
    .stable,
    .{ .answered = 1 },
    .{ .answered = 2 },
};

fn walk(s: Gate, w: World, depth: usize) !void {
    if (depth == 0) return;
    for (alphabet) |event| {
        if (event == .asked and find2(&s, event.asked.call)) continue;
        var next = s;
        var nw = w;
        var out: Output = .{};
        try next.step(event, &out);
        try nw.check(&next, &s, event, &out);
        try walk(next, nw, depth - 1);
    }
}

fn find2(s: *const Gate, handle: Handle) bool {
    for (s.calls) |c| if (c.used and c.handle == handle) return true;
    return false;
}

test "every event sequence to depth 6 keeps the model's invariants" {
    try walk(.init(.{ .max_attempts = 2 }), .{}, 6);
}

test "random long sequences keep the model's invariants, past max_calls" {
    var prng: std.Random.DefaultPrng = .init(0x12);
    const random = prng.random();
    for (0..200) |_| {
        var s: Gate = .init(.{ .max_attempts = 3 });
        var w: World = .{};
        var handle: Handle = 1;
        for (0..300) |_| {
            const event: Event = switch (random.uintLessThan(u8, 11)) {
                0 => blk: {
                    handle += 1;
                    break :blk .{ .asked = .{ .call = handle, .allowed = random.boolean() } };
                },
                1 => .need,
                2 => .{ .cancel = random.uintAtMost(Handle, handle) },
                3 => .{ .drop = .{ .keep = random.boolean() } },
                4 => .up,
                5 => .down,
                6 => .backoff_over,
                7 => .stable,
                8 => .broken,
                else => .{ .answered = random.uintAtMost(Handle, handle) },
            };
            const before = s;
            var out: Output = .{};
            s.step(event, &out) catch |err| {
                try testing.expectEqual(error.TooManyCalls, err);
                try testing.expectEqualDeep(before, s);
                continue;
            };
            try w.check(&s, &before, event, &out);
        }
    }
}

fn run(s: *Gate, event: Event) !Output {
    var out: Output = .{};
    try s.step(event, &out);
    return out;
}

test "a refused call never reaches the server or starts it (LazyConnect)" {
    var s: Gate = .init(.{});
    const out = try run(&s, .{ .asked = .{ .call = 7, .allowed = false } });
    try testing.expectEqualSlices(Effect, &.{.{ .end = .{ .call = 7, .end = .denied } }}, out.effects());
    try testing.expectEqual(Phase.idle, s.phase);
}

test "a call waits for its server, which starts for it, and goes out when it is ready" {
    var s: Gate = .init(.{});
    var out = try run(&s, .{ .asked = .{ .call = 1, .allowed = true } });
    try testing.expectEqualSlices(Effect, &.{.connect}, out.effects());
    try testing.expectEqual(Phase.idle, out.mid.?.phase);
    out = try run(&s, .need);
    try testing.expectEqual(@as(usize, 0), out.effect_count);
    out = try run(&s, .up);
    try testing.expectEqualSlices(Effect, &.{ .list, .{ .send = 1 }, .{ .arm_stable = 60_000 } }, out.effects());
    out = try run(&s, .{ .asked = .{ .call = 2, .allowed = true } });
    try testing.expectEqualSlices(Effect, &.{.{ .send = 2 }}, out.effects());
    out = try run(&s, .need);
    try testing.expect(out.ignored);
    try testing.expectEqualSlices(Effect, &.{.list}, out.effects());
}

test "a call fails with the start it waited for; the server backs off, then gives up" {
    var s: Gate = .init(.{ .max_attempts = 2 });
    _ = try run(&s, .{ .asked = .{ .call = 1, .allowed = true } });
    var out = try run(&s, .down);

    try testing.expectEqualSlices(Effect, &.{ .{ .end = .{ .call = 1, .end = .failed } }, .{ .arm_backoff = 5000 } }, out.effects());
    out = try run(&s, .backoff_over);
    try testing.expectEqualSlices(Effect, &.{.connect}, out.effects());

    _ = try run(&s, .{ .asked = .{ .call = 4, .allowed = true } });
    _ = try run(&s, .need);
    out = try run(&s, .down);
    try testing.expectEqualSlices(Effect, &.{ .{ .end = .{ .call = 4, .end = .failed } }, .refuse_need }, out.effects());
    try testing.expectEqual(Phase.failed, s.phase);
    out = try run(&s, .{ .asked = .{ .call = 2, .allowed = true } });
    try testing.expectEqualSlices(Effect, &.{.{ .end = .{ .call = 2, .end = .failed } }}, out.effects());

    _ = try run(&s, .{ .asked = .{ .call = 3, .allowed = false } });
    out = try run(&s, .{ .drop = .{ .keep = true } });
    try testing.expectEqualSlices(Effect, &.{.teardown}, out.effects());
    try testing.expectEqual(Phase.idle, s.phase);
}

test "a server that dies soon after each start starts again by itself, then gives up" {
    var s: Gate = .init(.{ .max_attempts = 2 });
    _ = try run(&s, .need);
    _ = try run(&s, .up);
    _ = try run(&s, .down);
    try testing.expectEqual(Phase.backoff, s.phase);

    var out = try run(&s, .backoff_over);
    try testing.expectEqualSlices(Effect, &.{.connect}, out.effects());
    _ = try run(&s, .up);
    out = try run(&s, .down);
    try testing.expectEqual(Phase.failed, s.phase);
    try testing.expect(!s.retry);
}

test "a server with no attempt limit retries without end, doubling from five seconds to five minutes" {
    var s: Gate = .init(.{});
    _ = try run(&s, .need);
    const expected = [_]u32{ 5_000, 10_000, 20_000, 40_000, 80_000, 160_000, 300_000, 300_000 };
    for (expected) |delay_ms| {
        const out = try run(&s, .down);
        try testing.expectEqualSlices(Effect, &.{.{ .arm_backoff = delay_ms }}, out.effects());
        try testing.expectEqual(Phase.backoff, s.phase);
        _ = try run(&s, .backoff_over);
        try testing.expectEqual(Phase.connecting, s.phase);
    }
    for (0..400) |_| {
        _ = try run(&s, .down);
        try testing.expectEqual(Phase.backoff, s.phase);
        _ = try run(&s, .backoff_over);
    }
    try testing.expectEqual(failure_streak_cap + 1, s.attempts);
}

test "a server with no attempt limit starts its failure streak over once it connects" {
    var s: Gate = .init(.{});
    _ = try run(&s, .need);
    for (0..3) |_| {
        _ = try run(&s, .down);
        _ = try run(&s, .backoff_over);
    }
    _ = try run(&s, .up);
    try testing.expectEqual(@as(u8, 0), s.attempts);
    const out = try run(&s, .down);
    try testing.expectEqualSlices(Effect, &.{.{ .arm_backoff = 5_000 }}, out.effects());
}

test "a failure that cannot recover by itself fails at once and is never retried" {
    var s: Gate = .init(.{});
    _ = try run(&s, .{ .asked = .{ .call = 1, .allowed = true } });
    _ = try run(&s, .need);
    var out = try run(&s, .broken);
    try testing.expectEqualSlices(Effect, &.{ .{ .end = .{ .call = 1, .end = .failed } }, .refuse_need }, out.effects());
    try testing.expectEqual(Phase.failed, s.phase);
    try testing.expect(!s.retry);
    try testing.expect((try run(&s, .backoff_over)).ignored);
    out = try run(&s, .{ .drop = .{ .keep = true } });
    try testing.expectEqual(Phase.idle, s.phase);
    out = try run(&s, .need);
    try testing.expectEqualSlices(Effect, &.{.connect}, out.effects());
}

test "the configured reconnect delays replace the five second start and five minute cap" {
    const config: Config = .{ .reconnect_initial_ms = 200, .reconnect_cap_ms = 700 };
    try testing.expectEqual(@as(u32, 200), config.reconnectDelay(0));
    try testing.expectEqual(@as(u32, 400), config.reconnectDelay(1));
    try testing.expectEqual(@as(u32, 700), config.reconnectDelay(2));
    try testing.expectEqual(@as(u32, 700), config.reconnectDelay(255));
}

test "jitter keeps a reconnect delay between half of it and all of it" {
    try testing.expectEqual(@as(u32, 2_500), jitteredDelay(5_000, 0));
    try testing.expectEqual(@as(u32, 3_750), jitteredDelay(5_000, 1 << 31));
    try testing.expectEqual(@as(u32, 4_999), jitteredDelay(5_000, std.math.maxInt(u32)));
    try testing.expectEqual(@as(u32, 0), jitteredDelay(0, std.math.maxInt(u32)));
    try testing.expectEqual(@as(u32, 0), jitteredDelay(1, std.math.maxInt(u32)));
}

test "a server that stayed up starts its tries over" {
    var s: Gate = .init(.{ .max_attempts = 2 });
    _ = try run(&s, .need);
    _ = try run(&s, .up);
    try testing.expectEqual(@as(u8, 1), s.attempts);
    var out = try run(&s, .stable);
    try testing.expect(!out.ignored);
    try testing.expectEqual(@as(u8, 0), s.attempts);
    out = try run(&s, .stable);
    try testing.expect(out.ignored);
    for (0..2) |_| {
        _ = try run(&s, .down);
        _ = try run(&s, .backoff_over);
        try testing.expectEqual(Phase.connecting, s.phase);
    }
    _ = try run(&s, .down);
    try testing.expectEqual(Phase.failed, s.phase);
}

test "a disconnected server never starts again by itself" {
    var s: Gate = .init(.{});
    _ = try run(&s, .need);
    _ = try run(&s, .up);
    _ = try run(&s, .down);
    try testing.expect(s.retry);
    const out = try run(&s, .{ .drop = .{ .keep = false } });
    try testing.expectEqualSlices(Effect, &.{.teardown}, out.effects());
    try testing.expect(!s.retry);
    try testing.expect((try run(&s, .backoff_over)).ignored);
    try testing.expectEqual(Phase.idle, s.phase);
}

test "a ready server's link dies: calls in flight are lost, and it starts again by itself" {
    var s: Gate = .init(.{});
    _ = try run(&s, .{ .asked = .{ .call = 1, .allowed = true } });
    _ = try run(&s, .up);
    var out = try run(&s, .down);
    try testing.expectEqualSlices(Effect, &.{ .{ .end = .{ .call = 1, .end = .lost } }, .{ .arm_backoff = 5000 } }, out.effects());
    out = try run(&s, .backoff_over);
    try testing.expectEqualSlices(Effect, &.{.connect}, out.effects());
    try testing.expectEqual(Phase.connecting, s.phase);
}

test "disconnect ends everything; reconnect keeps what waits and starts again" {
    var s: Gate = .init(.{});
    _ = try run(&s, .{ .asked = .{ .call = 1, .allowed = true } });
    _ = try run(&s, .up);
    _ = try run(&s, .down);
    _ = try run(&s, .{ .asked = .{ .call = 2, .allowed = true } });
    var out = try run(&s, .{ .drop = .{ .keep = true } });
    try testing.expectEqualSlices(Effect, &.{ .teardown, .connect }, out.effects());
    out = try run(&s, .{ .drop = .{ .keep = false } });
    try testing.expectEqualSlices(Effect, &.{ .teardown, .{ .end = .{ .call = 2, .end = .cancelled } } }, out.effects());
    try testing.expectEqual(Phase.idle, s.phase);
}
