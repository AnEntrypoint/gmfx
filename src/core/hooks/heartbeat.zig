const std = @import("std");
const io_mod = @import("../shared/io.zig");
const external = @import("external.zig");

const Allocator = std.mem.Allocator;

const poll_interval_ms: u64 = 50;

pub const Tick = *const fn (ctx: *anyopaque, uptime_ms: i64) void;

pub const Heartbeat = struct {
    worker: *Worker,
    thread: std.Thread,

    const Worker = struct {
        ctx: *anyopaque,
        tick: Tick,
        cancel: std.atomic.Value(bool),
        interval_ms: u64,
    };

    pub fn start(alloc: Allocator, ctx: *anyopaque, tick: Tick) !Heartbeat {
        return startWithInterval(alloc, ctx, tick, external.heartbeat_interval_ms);
    }

    fn startWithInterval(alloc: Allocator, ctx: *anyopaque, tick: Tick, interval_ms: u64) !Heartbeat {
        const worker = try alloc.create(Worker);
        errdefer alloc.destroy(worker);
        worker.* = .{
            .ctx = ctx,
            .tick = tick,
            .cancel = std.atomic.Value(bool).init(false),
            .interval_ms = interval_ms,
        };
        const thread = try std.Thread.spawn(.{}, runWorker, .{worker});
        return .{ .worker = worker, .thread = thread };
    }

    pub fn stop(self: *Heartbeat, alloc: Allocator) void {
        self.worker.cancel.store(true, .release);
        self.thread.join();
        alloc.destroy(self.worker);
        self.* = undefined;
    }
};

fn cancelled(worker: *Heartbeat.Worker) bool {
    return worker.cancel.load(.acquire);
}

fn runWorker(worker: *Heartbeat.Worker) void {
    const started_ms = io_mod.milliTimestamp();
    while (true) {
        var waited_ms: u64 = 0;
        while (waited_ms < worker.interval_ms) : (waited_ms += poll_interval_ms) {
            if (cancelled(worker)) return;
            io_mod.sleep(poll_interval_ms * std.time.ns_per_ms);
        }
        if (cancelled(worker)) return;
        worker.tick(worker.ctx, io_mod.milliTimestamp() - started_ms);
    }
}

const Counter = struct {
    ticks: std.atomic.Value(u32) = .init(0),

    fn tick(ctx: *anyopaque, uptime_ms: i64) void {
        _ = uptime_ms;
        const self: *Counter = @ptrCast(@alignCast(ctx));
        _ = self.ticks.fetchAdd(1, .seq_cst);
    }
};

test "heartbeat stops on cancel without ticking before its interval elapses" {
    const alloc = std.testing.allocator;
    var counter: Counter = .{};
    var heartbeat = try Heartbeat.start(alloc, &counter, Counter.tick);
    heartbeat.stop(alloc);
    try std.testing.expectEqual(@as(u32, 0), counter.ticks.load(.seq_cst));
}

test "heartbeat ticks once per interval and stops after the next cancel" {
    const alloc = std.testing.allocator;
    var counter: Counter = .{};
    var heartbeat = try Heartbeat.startWithInterval(alloc, &counter, Counter.tick, 10);
    while (counter.ticks.load(.seq_cst) == 0) io_mod.sleep(5 * std.time.ns_per_ms);
    heartbeat.stop(alloc);
    try std.testing.expect(counter.ticks.load(.seq_cst) >= 1);
}
