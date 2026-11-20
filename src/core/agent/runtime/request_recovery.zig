const std = @import("std");
const builtin = @import("builtin");
const recovery = @import("../../recovery/recovery.zig");
const types = @import("../../shared/types.zig");
const io_mod = @import("../../shared/io.zig");
const debug_trace = @import("../../shared/debug_trace.zig");
const agent_stream_provider = @import("../stream_provider.zig");
const runtime_deps = @import("deps.zig");

pub const Failure = recovery.Failure;
pub const Send = recovery.Send;

const tick_ms: u64 = 1_000;
const wait_tick_ms: u64 = 100;
const cancel_poll_ms: u64 = 25;
const ticker_interval_ns: i96 = if (builtin.is_test) 5 * std.time.ns_per_ms else tick_ms * std.time.ns_per_ms;
const test_epoch_ms: u64 = 1_000_000;

pub fn failureKind(cause: types.ModelRecoveryCause) ?Failure.Kind {
    return switch (cause) {
        .connectivity_lost => .offline,

        .network_interrupted, .response_interrupted, .provider_stream_timeout => .dropped,
        .provider_unavailable => .server,
        .rate_limited => .rate_limited,
        .authentication, .request_limit_reached, .compaction_prepared => null,
    };
}

const max_unreadable_replies = 3;
const max_incomplete_replies = 6;

pub const RequestRecovery = struct {
    deps: *const runtime_deps.AgentRuntimeDeps,
    cancel_flag: *std.atomic.Value(bool),
    trace_ctx: debug_trace.TraceContext,
    continue_flag: ?*std.atomic.Value(bool) = null,
    ticker_enabled: bool = !builtin.is_test,
    unreadable_replies: u8 = 0,
    incomplete_replies: u8 = 0,
    registry_node: std.DoublyLinkedList.Node = .{},
    registered: bool = false,

    mutex: std.Io.Mutex = .init,

    state: recovery.State = .{},
    attempts: u16 = 0,
    send: Send = .{},
    recovery_shown: bool = false,
    responded: bool = false,
    host_showing: bool = false,
    ticker: ?std.Thread = null,
    ticker_stop: bool = false,
    ticker_wake: std.Io.Condition = .init,
    inner_pulse: ?agent_stream_provider.CooperativePulse = null,
    record: ?recovery.Record = null,
    record_written: bool = false,
    record_live: bool = false,
    closed: bool = false,
    next_beat_ms: u64 = 0,
    virtual_now_ms: std.atomic.Value(u64) = .init(test_epoch_ms),

    pub fn init(
        deps: *const runtime_deps.AgentRuntimeDeps,
        cancel_flag: *std.atomic.Value(bool),
        trace_ctx: debug_trace.TraceContext,
    ) RequestRecovery {
        return .{ .deps = deps, .cancel_flag = cancel_flag, .trace_ctx = trace_ctx };
    }

    pub fn deinit(self: *RequestRecovery) void {
        unregister(self);
        self.endSend();
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.clearShownLocked();
    }

    pub const Resume = types.RecoveryResume;

    pub fn start(self: *RequestRecovery, fast: bool, resumed: ?Resume) !?Send {
        if (self.deps.begin_route_recovery_request) |begin| begin(self.deps.ctx);
        if (self.deps.save_recovery_record != null) register(self);
        const from = resumed orelse Resume{};
        return self.event(.{ .start = .{ .fast = fast, .resume_from = from.record, .stale = from.stale } });
    }

    pub fn sendRecord(self: *RequestRecovery) types.RecoveryRecordWrite {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.closed or self.deps.save_recovery_record == null or self.record_written) return .keep;
        const record = self.record orelse return .keep;
        self.record_written = true;
        self.record_live = true;
        return .{ .save = record };
    }

    pub fn responseRecord(self: *RequestRecovery, complete: bool) types.RecoveryRecordWrite {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (!complete or self.closed or !self.record_live) return .keep;
        self.record_live = false;
        return .clear;
    }

    pub fn flushRecord(self: *RequestRecovery) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.writeRecordLocked();
    }

    pub fn closeActive() usize {
        const io = io_mod.getIo();
        if (!lockWithin(&registry_mutex, close_wait_ms)) {
            debug_trace.logf("recovery", "closing skipped every request reason=registry_busy", .{});
            return 0;
        }
        defer registry_mutex.unlock(io);
        var written: usize = 0;
        var node = registry.first;
        while (node) |current| : (node = current.next) {
            const request: *RequestRecovery = @fieldParentPtr("registry_node", current);
            if (request.close()) written += 1;
        }
        return written;
    }

    fn close(self: *RequestRecovery) bool {
        const io = io_mod.getIo();
        if (!lockWithin(&self.mutex, close_wait_ms)) {
            debug_trace.eventf("recovery", "closing_skipped", self.trace_ctx, "reason=request_busy", .{});
            return false;
        }
        defer self.mutex.unlock(io);
        if (self.closed) return false;
        _ = self.stepLocked(.closing) catch |err| {
            debug_trace.logf("recovery", "closing status publication failed err={s}", .{@errorName(err)});
        };
        const written = self.record_written;
        self.closed = true;
        debug_trace.eventf("recovery", "closed", self.trace_ctx, "record_written={}", .{written});
        return written;
    }

    pub fn failed(self: *RequestRecovery, failure: Failure) !?Send {
        if (self.continue_flag) |flag| flag.store(false, .seq_cst);
        return self.event(.{ .failed = failure });
    }

    pub fn canAskUser(self: *const RequestRecovery) bool {
        return self.continue_flag != null;
    }

    pub fn userContinue(self: *RequestRecovery) !?Send {
        return self.event(.user_continue);
    }

    pub fn waitForSend(self: *RequestRecovery) !?Send {
        var next_tick_ms = self.nowMs() +| wait_tick_ms;
        while (true) {
            if (self.cancel_flag.load(.seq_cst)) return null;
            if (self.continue_flag) |flag| if (flag.swap(false, .seq_cst)) {
                if (try self.event(.user_continue)) |send| return send;
            };
            const now_ms = self.nowMs();
            if (now_ms < next_tick_ms) {
                self.sleepMs(@min(cancel_poll_ms, next_tick_ms - now_ms));
                continue;
            }
            next_tick_ms = now_ms +| wait_tick_ms;
            if (try self.event(.tick)) |send| return send;
        }
    }

    pub fn responding(self: *RequestRecovery) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.responded) return;
        self.responded = true;
        _ = self.stepLocked(.responding) catch |err| {
            debug_trace.logf("recovery", "responding status publication failed err={s}", .{@errorName(err)});
        };
    }

    pub fn succeeded(self: *RequestRecovery) !void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        _ = try self.stepLocked(.succeeded);
        if (!self.recovery_shown) return;
        self.recovery_shown = false;
        self.host_showing = false;
        try self.deps.push_route_recovery_status(self.deps.ctx, .{
            .kind = .recovered,
            .attempt = self.attempts,
        });
    }

    pub fn cancel(self: *RequestRecovery) !void {
        _ = try self.event(.user_cancel);
    }

    pub fn replaceStatus(self: *RequestRecovery, status: types.RouteRecoveryStatus) !void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.host_showing = false;
        self.recovery_shown = false;
        try self.deps.push_route_recovery_status(self.deps.ctx, status);
    }

    pub fn endWithError(self: *RequestRecovery) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (!self.recovery_shown) return self.clearShownLocked();
        self.recovery_shown = false;
        self.host_showing = false;
        self.deps.push_route_recovery_status(self.deps.ctx, .{
            .kind = .failed,
            .attempt = self.attempts,
        }) catch |err| {
            debug_trace.logf("recovery", "failed status publication failed err={s}", .{@errorName(err)});
        };
    }

    fn clearShownLocked(self: *RequestRecovery) void {
        if (!self.host_showing) return;
        self.host_showing = false;
        self.deps.push_event(self.deps.ctx, .clear_route_recovery_status) catch |err| {
            debug_trace.logf("recovery", "stale status clear failed err={s}", .{@errorName(err)});
        };
    }

    pub fn unreadableReplyEndsRequest(self: *RequestRecovery) bool {
        self.unreadable_replies +|= 1;
        return self.unreadable_replies >= max_unreadable_replies;
    }

    pub fn incompleteReplyEndsRequest(self: *RequestRecovery) bool {
        self.incomplete_replies +|= 1;
        return self.incomplete_replies >= max_incomplete_replies;
    }

    pub fn attempt(self: *RequestRecovery) u16 {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.attempts;
    }

    pub fn beginSend(self: *RequestRecovery) void {
        if (comptime builtin.single_threaded) {
            self.next_beat_ms = self.nowMs() +| tick_ms;
            return;
        }
        if (!self.ticker_enabled or self.ticker != null) return;
        self.ticker_stop = false;
        self.ticker = std.Thread.spawn(.{}, tickerMain, .{self}) catch |err| {
            debug_trace.logf("recovery", "status ticker unavailable err={s}", .{@errorName(err)});
            return;
        };
    }

    pub fn endSend(self: *RequestRecovery) void {
        const thread = self.ticker orelse return;
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        self.ticker_stop = true;
        self.ticker_wake.signal(io);
        self.mutex.unlock(io);
        thread.join();
        self.ticker = null;
    }

    pub fn cooperativePulse(
        self: *RequestRecovery,
        inner: ?agent_stream_provider.CooperativePulse,
    ) ?agent_stream_provider.CooperativePulse {
        if (comptime !builtin.single_threaded) return inner;
        self.inner_pulse = inner;
        return .{ .ctx = self, .run = pulseBeat };
    }

    fn pulseBeat(raw: *anyopaque) anyerror!void {
        const self: *RequestRecovery = @ptrCast(@alignCast(raw));
        const now_ms = self.nowMs();
        if (now_ms >= self.next_beat_ms) {
            self.next_beat_ms = now_ms +| tick_ms;
            _ = self.event(.tick) catch |err| {
                debug_trace.logf("recovery", "status tick publication failed err={s}", .{@errorName(err)});
            };
        }
        if (self.inner_pulse) |inner| try inner.pulse();
    }

    fn tickerMain(self: *RequestRecovery) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (!self.ticker_stop) {
            self.ticker_wake.waitTimeout(io, &self.mutex, .{ .duration = .{
                .raw = .fromNanoseconds(ticker_interval_ns),
                .clock = .awake,
            } }) catch |err| switch (err) {
                error.Timeout => {},
                error.Canceled => return,
            };
            if (self.ticker_stop) return;
            _ = self.stepLocked(.tick) catch |err| {
                debug_trace.logf("recovery", "status tick publication failed err={s}", .{@errorName(err)});
            };
        }
    }

    fn event(self: *RequestRecovery, value: recovery.Event) !?Send {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.stepLocked(value);
    }

    fn stepLocked(self: *RequestRecovery, value: recovery.Event) !?Send {
        if (self.closed) return null;
        const now_ms = self.nowMs();
        const plan = recovery.step(&self.state, value, now_ms);
        if (plan.send) |send| {
            self.attempts +|= 1;
            self.send = send;
            self.responded = false;
        }
        if (plan.send != null or plan.status != null or plan.finish != null) {
            debug_trace.eventf("recovery", "step", self.trace_ctx, "event={s} now_ms={d} attempt={d} send={s} no_fast={} status={s} finish={s}", .{
                @tagName(value),
                now_ms,
                self.attempts,
                if (plan.send != null) "true" else "false",
                self.send.no_fast,
                if (plan.status) |status| @tagName(status.kind) else "none",
                if (plan.finish) |finish| @tagName(finish) else "none",
            });
        }
        if (plan.save) |record| {
            self.record = record;
            self.record_written = false;

            if (plan.send == null) self.writeRecordLocked();
        }
        if (plan.status) |status| try self.showLocked(status);
        if (plan.finish) |finish| switch (finish) {
            .succeeded => if (self.record_live) {
                _ = self.saveLocked(.clear);
            },

            .cancelled => self.recovery_shown = false,
        };
        return plan.send;
    }

    fn writeRecordLocked(self: *RequestRecovery) void {
        if (self.record_written) return;
        const record = self.record orelse return;
        if (self.saveLocked(.{ .save = record })) {
            self.record_written = true;
            self.record_live = true;
        }
    }

    fn saveLocked(self: *RequestRecovery, write: types.RecoveryRecordWrite) bool {
        const save = self.deps.save_recovery_record orelse return false;
        const written = save(self.deps.ctx, write) catch |err| {
            debug_trace.logf("recovery", "record {s} failed err={s}", .{ @tagName(write), @errorName(err) });
            return false;
        };
        if (written and write == .clear) self.record_live = false;
        return written;
    }

    fn showLocked(self: *RequestRecovery, status: recovery.Status) !void {
        if (types.RouteRecoveryStatus.fromRecovery(status, self.attempts)) |shown| {
            self.recovery_shown = true;
            self.host_showing = true;
            try self.deps.push_route_recovery_status(self.deps.ctx, shown);
        } else {
            self.host_showing = false;
            try self.deps.push_event(self.deps.ctx, .clear_route_recovery_status);
        }
    }

    fn nowMs(self: *RequestRecovery) u64 {
        if (comptime builtin.is_test) return self.virtual_now_ms.load(.seq_cst);
        const ns = std.Io.Clock.Timestamp.now(io_mod.getIo(), .boot).raw.toNanoseconds();
        return if (ns <= 0) 0 else @intCast(@divTrunc(ns, std.time.ns_per_ms));
    }

    fn sleepMs(self: *RequestRecovery, ms: u64) void {
        if (comptime builtin.is_test) {
            _ = self.virtual_now_ms.fetchAdd(ms, .seq_cst);
            return;
        }

        if (comptime builtin.single_threaded) {
            if (self.inner_pulse) |inner| inner.pulse() catch |err| {
                debug_trace.logf("recovery", "wait pulse failed err={s}", .{@errorName(err)});
            };
        }
        io_mod.getIo().sleep(.fromNanoseconds(@as(i96, ms) * std.time.ns_per_ms), .awake) catch {};
    }
};

const close_wait_ms: u64 = 1_000;

fn lockWithin(mutex: *std.Io.Mutex, ms: u64) bool {
    var waited_ms: u64 = 0;
    while (!mutex.tryLock()) {
        if (waited_ms >= ms) return false;
        io_mod.getIo().sleep(.fromNanoseconds(5 * std.time.ns_per_ms), .awake) catch {};
        waited_ms += 5;
    }
    return true;
}

var registry_mutex: std.Io.Mutex = .init;
var registry: std.DoublyLinkedList = .{};

fn register(request: *RequestRecovery) void {
    const io = io_mod.getIo();
    registry_mutex.lockUncancelable(io);
    defer registry_mutex.unlock(io);
    if (request.registered) return;
    registry.append(&request.registry_node);
    request.registered = true;
}

fn unregister(request: *RequestRecovery) void {
    const io = io_mod.getIo();
    registry_mutex.lockUncancelable(io);
    defer registry_mutex.unlock(io);
    if (!request.registered) return;
    registry.remove(&request.registry_node);
    request.registry_node = .{};
    request.registered = false;
}

const support = @import("tests/support.zig");

fn statusTexts(fake: *const support.FakeAgentRuntimeDeps, buf: [][]const u8) [][]const u8 {
    var count: usize = 0;
    for (fake.route_recovery_statuses.items) |*status| {
        if (count == buf.len) break;
        buf[count] = status.text.slice();
        count += 1;
    }
    return buf[0..count];
}

test "a transient failure waits with the module's status, then resends" {
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    defer request.deinit();

    _ = try request.start(false, null);
    try std.testing.expectEqual(@as(u16, 1), request.attempt());
    try std.testing.expectEqual(@as(usize, 0), fake.route_recovery_statuses.items.len);

    _ = try request.failed(.{ .kind = .dropped });
    const waiting = fake.route_recovery_statuses.items[0];
    try std.testing.expectEqual(types.RouteRecoveryStatus.Kind.waiting, waiting.kind);
    try std.testing.expectEqualStrings("Connection lost · next try in 1s · attempt 1", waiting.text.slice());
    try std.testing.expectEqual(@as(usize, 1), waiting.attempt);

    const send = (try request.waitForSend()).?;
    try std.testing.expectEqual(Send{}, send);
    try std.testing.expectEqual(@as(u16, 2), request.attempt());
    const retrying = fake.route_recovery_statuses.items[fake.route_recovery_statuses.items.len - 1];
    try std.testing.expectEqual(types.RouteRecoveryStatus.Kind.retrying, retrying.kind);
    try std.testing.expect(std.mem.startsWith(u8, retrying.text.slice(), "Connection lost · retrying · attempt 2"));
}

test "the first output clears the status and success reports the recovery" {
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    defer request.deinit();

    _ = try request.start(false, null);
    _ = try request.failed(.{ .kind = .server });
    _ = (try request.waitForSend()).?;
    const shown = fake.route_recovery_statuses.items.len;

    request.responding();
    try std.testing.expectEqual(@as(usize, 1), fake.route_recovery_clear_count);

    request.responding();
    try std.testing.expectEqual(@as(usize, 1), fake.route_recovery_clear_count);

    try request.succeeded();
    try std.testing.expectEqual(shown + 1, fake.route_recovery_statuses.items.len);
    const recovered = fake.route_recovery_statuses.items[shown];
    try std.testing.expectEqual(types.RouteRecoveryStatus.Kind.recovered, recovered.kind);
    try std.testing.expectEqual(@as(usize, 2), recovered.attempt);

    try std.testing.expectEqual(@as(usize, 0), recovered.text.len);
}

test "responding from two threads at once delivers one responding" {
    if (comptime builtin.single_threaded) return error.SkipZigTest;
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    defer request.deinit();

    _ = try request.start(false, null);
    for (0..50) |_| {
        _ = try request.failed(.{ .kind = .dropped });
        _ = (try request.waitForSend()).?;
        const clears = fake.route_recovery_clear_count;
        const racer = try std.Thread.spawn(.{}, RequestRecovery.responding, .{&request});
        request.responding();
        racer.join();

        try std.testing.expectEqual(clears + 1, fake.route_recovery_clear_count);
    }
}

test "a healthy request shows nothing and reports no recovery" {
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    defer request.deinit();

    _ = try request.start(true, null);
    request.responding();
    try request.succeeded();
    try std.testing.expectEqual(@as(usize, 0), fake.route_recovery_statuses.items.len);
    try std.testing.expectEqual(@as(usize, 0), fake.route_recovery_clear_count);
}

test "Esc during a wait stops waiting and cancel clears the status" {
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    var cancel_flag = std.atomic.Value(bool).init(false);
    fake.cancel_on_auto_retry_status = &cancel_flag;
    const deps = fake.deps();
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    defer request.deinit();

    _ = try request.start(false, null);
    _ = try request.failed(.{ .kind = .rate_limited, .retry_after_ms = 20_000 });
    try std.testing.expect(cancel_flag.load(.seq_cst));
    try std.testing.expect(try request.waitForSend() == null);
    try std.testing.expectEqual(@as(u16, 1), request.attempt());

    try request.cancel();
    try std.testing.expectEqual(@as(usize, 1), fake.route_recovery_clear_count);

    try request.succeeded();
    try std.testing.expectEqual(@as(usize, 1), fake.route_recovery_statuses.items.len);
}

test "three server errors in a row with Fast on resend without Fast" {
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    defer request.deinit();

    _ = try request.start(true, null);
    for (0..2) |_| {
        _ = try request.failed(.{ .kind = .server });
        try std.testing.expectEqual(Send{}, (try request.waitForSend()).?);
    }
    _ = try request.failed(.{ .kind = .server });
    const send = (try request.waitForSend()).?;
    try std.testing.expect(send.no_fast);
    try std.testing.expect(request.send.no_fast);
    const retrying = fake.route_recovery_statuses.items[fake.route_recovery_statuses.items.len - 1];
    try std.testing.expect(std.mem.startsWith(u8, retrying.text.slice(), "Gateway error · retrying without Fast · attempt 4"));

    _ = try request.failed(.{ .kind = .dropped });
    try std.testing.expect((try request.waitForSend()).?.no_fast);
}

test "a server's Retry-After is honored up to the 30 second ceiling" {
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    defer request.deinit();

    _ = try request.start(false, null);
    _ = try request.failed(.{ .kind = .server, .retry_after_ms = 3_000 });
    try std.testing.expectEqualStrings("Gateway error · next try in 3s · attempt 1", fake.route_recovery_statuses.items[0].text.slice());
    var started_ms = request.nowMs();
    _ = (try request.waitForSend()).?;
    try std.testing.expectEqual(@as(u64, 3_000), request.nowMs() - started_ms);

    _ = try request.failed(.{ .kind = .server, .retry_after_ms = 120_000 });
    try std.testing.expect(std.mem.startsWith(u8, fake.route_recovery_statuses.items[fake.route_recovery_statuses.items.len - 1].text.slice(), "Gateway error · next try in 30s · attempt 2"));
    started_ms = request.nowMs();
    _ = (try request.waitForSend()).?;
    try std.testing.expectEqual(@as(u64, 30_000), request.nowMs() - started_ms);
}

test "the countdown refreshes once a second while waiting" {
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    defer request.deinit();

    _ = try request.start(false, null);
    _ = try request.failed(.{ .kind = .rate_limited, .retry_after_ms = 3_000 });
    _ = (try request.waitForSend()).?;
    var buf: [8][]const u8 = undefined;
    const texts = statusTexts(&fake, &buf);
    try std.testing.expectEqual(@as(usize, 4), texts.len);
    try std.testing.expectEqualStrings("Rate limited · next try in 3s · attempt 1", texts[0]);
    try std.testing.expectEqualStrings("Rate limited · next try in 2s · attempt 1", texts[1]);
    try std.testing.expectEqualStrings("Rate limited · next try in 1s · attempt 1", texts[2]);
    try std.testing.expectEqualStrings("Rate limited · retrying · attempt 2", texts[3]);
}

test "the in-flight ticker hands the line back to the thinking row" {
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    request.ticker_enabled = true;
    defer request.deinit();

    _ = try request.start(false, null);
    _ = try request.failed(.{ .kind = .dropped });
    _ = (try request.waitForSend()).?;
    const io = io_mod.getIo();
    request.mutex.lockUncancelable(io);
    const statuses_before = fake.route_recovery_statuses.items.len;
    const clears_before = fake.route_recovery_clear_count;
    request.mutex.unlock(io);

    request.beginSend();
    if (comptime builtin.single_threaded) return error.SkipZigTest;

    _ = request.virtual_now_ms.fetchAdd(2_000, .seq_cst);
    var waited_ms: usize = 0;
    while (waited_ms < 2_000) : (waited_ms += 5) {
        request.mutex.lockUncancelable(io);
        const clears = fake.route_recovery_clear_count;
        request.mutex.unlock(io);
        if (clears > clears_before) break;
        io.sleep(.fromNanoseconds(5 * std.time.ns_per_ms), .awake) catch {};
    }
    request.endSend();

    try std.testing.expectEqual(clears_before + 1, fake.route_recovery_clear_count);
    try std.testing.expectEqual(statuses_before, fake.route_recovery_statuses.items.len);
}

test "start tells the host a new request begins" {
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    var deps = fake.deps();
    const Host = struct {
        var begun: usize = 0;
        fn begin(_: *anyopaque) void {
            begun += 1;
        }
    };
    Host.begun = 0;
    deps.begin_route_recovery_request = Host.begin;
    var cancel_flag = std.atomic.Value(bool).init(false);
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    defer request.deinit();

    _ = try request.start(false, null);
    try std.testing.expectEqual(@as(usize, 1), Host.begun);
}

test "an error after a status reports failed and every exit clears the status" {
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);

    {
        var request = RequestRecovery.init(&deps, &cancel_flag, .{});
        defer request.deinit();
        _ = try request.start(false, null);
        _ = try request.failed(.{ .kind = .server });
        _ = (try request.waitForSend()).?;
        request.endWithError();
        const last = fake.route_recovery_statuses.items[fake.route_recovery_statuses.items.len - 1];
        try std.testing.expectEqual(types.RouteRecoveryStatus.Kind.failed, last.kind);
        try std.testing.expectEqual(@as(usize, 2), last.attempt);
    }

    try std.testing.expectEqual(@as(usize, 0), fake.route_recovery_clear_count);

    const shown = fake.route_recovery_statuses.items.len;
    {
        var request = RequestRecovery.init(&deps, &cancel_flag, .{});
        defer request.deinit();
        _ = try request.start(false, null);
        _ = try request.failed(.{ .kind = .dropped });

        try request.replaceStatus(.{ .kind = .terminal_provider_error, .attempt = 1 });
        request.endWithError();
    }
    try std.testing.expectEqual(shown + 2, fake.route_recovery_statuses.items.len);
    try std.testing.expectEqual(@as(usize, 0), fake.route_recovery_clear_count);

    {
        var request = RequestRecovery.init(&deps, &cancel_flag, .{});
        defer request.deinit();
        _ = try request.start(false, null);
        _ = try request.failed(.{ .kind = .dropped });
    }
    try std.testing.expectEqual(@as(usize, 1), fake.route_recovery_clear_count);
}

fn recordingFake() support.FakeAgentRuntimeDeps {
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    fake.enable_recovery_record = true;
    return fake;
}

test "a send's save travels with its write, and a wait's is written at once" {
    var fake = recordingFake();
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    defer request.deinit();

    _ = (try request.start(false, null)).?;
    try std.testing.expectEqual(@as(usize, 0), fake.recovery_record_writes);
    const first = request.sendRecord();
    try std.testing.expect(first == .save);

    try std.testing.expect(request.sendRecord() == .keep);

    try std.testing.expectEqual(@as(?Send, null), try request.failed(.{ .kind = .dropped }));
    try std.testing.expectEqual(@as(usize, 1), fake.recovery_record_writes);
    try std.testing.expect(!std.mem.eql(u8, &first.save, &fake.recovery_record.?));

    _ = (try request.waitForSend()).?;
    try std.testing.expect(request.sendRecord() == .save);

    try std.testing.expect(request.responseRecord(true) == .clear);
    try request.succeeded();
    try std.testing.expectEqual(@as(usize, 0), fake.recovery_record_clears);
}

test "a success whose response write never ran clears through the host" {
    var fake = recordingFake();
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    defer request.deinit();

    _ = (try request.start(false, null)).?;
    _ = request.sendRecord();

    try std.testing.expect(request.responseRecord(false) == .keep);
    try request.succeeded();
    try std.testing.expectEqual(@as(usize, 1), fake.recovery_record_clears);
}

test "closing saves a clean record that resumes without a death, and nothing replaces it" {
    var fake = recordingFake();
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);
    {
        var request = RequestRecovery.init(&deps, &cancel_flag, .{});
        defer request.deinit();
        _ = (try request.start(false, null)).?;
        _ = request.sendRecord();
        try std.testing.expectEqual(@as(usize, 1), RequestRecovery.closeActive());
        const saved = fake.recovery_record.?;

        try std.testing.expectEqual(@as(?Send, null), try request.failed(.{ .kind = .dropped }));
        try std.testing.expectEqual(saved, fake.recovery_record.?);
        try std.testing.expectEqual(@as(usize, 0), RequestRecovery.closeActive());
    }

    try std.testing.expectEqual(@as(usize, 0), RequestRecovery.closeActive());

    var probe: recovery.State = .{};
    const plan = recovery.step(&probe, .{ .start = .{ .resume_from = fake.recovery_record.? } }, 0);
    try std.testing.expect(plan.send != null);
    try std.testing.expectEqual(@as(u8, 0), probe.abrupt_deaths);
}

test "closing saves a clean record for every request in flight" {
    var main_fake = recordingFake();
    defer main_fake.deinit();
    var subagent_fake = recordingFake();
    defer subagent_fake.deinit();
    var ended_fake = recordingFake();
    defer ended_fake.deinit();
    const main_deps = main_fake.deps();
    const subagent_deps = subagent_fake.deps();
    const ended_deps = ended_fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);

    var main_request = RequestRecovery.init(&main_deps, &cancel_flag, .{});
    defer main_request.deinit();
    _ = (try main_request.start(false, null)).?;
    _ = main_request.sendRecord();

    {
        var ended = RequestRecovery.init(&ended_deps, &cancel_flag, .{});
        defer ended.deinit();
        _ = (try ended.start(false, null)).?;
        _ = ended.sendRecord();
    }

    var subagent_request = RequestRecovery.init(&subagent_deps, &cancel_flag, .{});
    defer subagent_request.deinit();
    _ = (try subagent_request.start(false, null)).?;
    _ = subagent_request.sendRecord();

    try std.testing.expectEqual(@as(usize, 2), RequestRecovery.closeActive());
    for ([_]*const support.FakeAgentRuntimeDeps{ &main_fake, &subagent_fake }) |fake| {
        var probe: recovery.State = .{};
        const plan = recovery.step(&probe, .{ .start = .{ .resume_from = fake.recovery_record.? } }, 0);
        try std.testing.expect(plan.send != null);
        try std.testing.expectEqual(@as(u8, 0), probe.abrupt_deaths);
    }
    try std.testing.expectEqual(@as(usize, 0), RequestRecovery.closeActive());
}

test "a resumed start that must ask first sends nothing" {
    var fake = recordingFake();
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);

    fake.recovery_turn_written = false;

    var probe: recovery.State = .{};
    const first = recovery.step(&probe, .{ .start = .{} }, 0).save.?;
    probe = .{};
    const second = recovery.step(&probe, .{ .start = .{ .resume_from = first } }, 0).save.?;
    {
        var request = RequestRecovery.init(&deps, &cancel_flag, .{});
        defer request.deinit();
        try std.testing.expectEqual(@as(?Send, null), try request.start(false, .{ .record = second }));

        try std.testing.expect(request.sendRecord() == .save);
    }
    {
        var request = RequestRecovery.init(&deps, &cancel_flag, .{});
        defer request.deinit();
        try std.testing.expectEqual(@as(?Send, null), try request.start(false, .{ .stale = true }));
    }
}

test "a resend leaves within one wait tick of its jittered deadline" {
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    const deps = fake.deps();
    var below: usize = 0;
    var seed: u64 = 0;
    while (seed < 40) : (seed += 1) {
        var cancel_flag = std.atomic.Value(bool).init(false);
        var request = RequestRecovery.init(&deps, &cancel_flag, .{});
        defer request.deinit();
        request.virtual_now_ms.store(test_epoch_ms + seed * 7_919, .seq_cst);
        _ = try request.start(false, null);
        _ = try request.failed(.{ .kind = .server });
        const failed_at = request.virtual_now_ms.load(.seq_cst);
        _ = (try request.waitForSend()).?;
        const waited = request.virtual_now_ms.load(.seq_cst) - failed_at;

        try std.testing.expect(waited >= 800 and waited <= 1_000 + wait_tick_ms);
        if (waited <= 950) below += 1;
        _ = try request.cancel();
    }

    try std.testing.expect(below >= 10);
}

test "ten thousand failures in a row keep every wait within its cap and never stop retrying" {
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    defer request.deinit();
    request.virtual_now_ms.store(test_epoch_ms, .seq_cst);
    _ = try request.start(false, null);
    var longest: u64 = 0;
    for (0..10_000) |_| {
        _ = try request.failed(.{ .kind = .server });
        const failed_at = request.virtual_now_ms.load(.seq_cst);
        _ = (try request.waitForSend()) orelse return error.TestExpectedSend;
        const waited = request.virtual_now_ms.load(.seq_cst) - failed_at;
        longest = @max(longest, waited);

        try std.testing.expect(waited <= 30_000 + wait_tick_ms);
    }
    try std.testing.expect(longest >= 24_000);
    _ = try request.cancel();
}
