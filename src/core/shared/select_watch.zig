const std = @import("std");
const builtin = @import("builtin");

pub const Outcome = enum { stopped, cancelled, deadline };

const poll_interval: std.Io.Timeout = .{ .duration = .{
    .raw = .fromMilliseconds(5),
    .clock = .awake,
} };

pub fn Watch(comptime Condition: type) type {
    return struct {
        stopped: std.Io.Event = .unset,

        const Self = @This();

        pub fn run(watch: *Self, io: std.Io, condition: Condition) std.Io.Cancelable!Outcome {
            while (true) {
                if (condition.cancelled()) return .cancelled;
                if (condition.expired(io)) return .deadline;
                watch.stopped.waitTimeout(io, poll_interval) catch |err| switch (err) {
                    error.Timeout => continue,
                    error.Canceled => |e| return e,
                };
                return .stopped;
            }
        }

        pub fn stop(watch: *Self, io: std.Io) void {
            watch.stopped.set(io);
        }

        pub fn finish(watch: *Self, select: anytype) void {
            watch.stop(select.io);
            const event = select.queue.getOneUncancelable(select.io) catch |err| switch (err) {
                error.Closed => return,
            };
            std.debug.assert(event == .watch);
            std.debug.assert(select.cancel() == null);
        }
    };
}

const TestCondition = struct {
    flag: *const std.atomic.Value(bool),
    deadline_ns: ?i96 = null,

    pub fn cancelled(condition: TestCondition) bool {
        return condition.flag.load(.acquire);
    }

    pub fn expired(condition: TestCondition, io: std.Io) bool {
        const deadline = condition.deadline_ns orelse return false;
        return std.Io.Clock.awake.now(io).nanoseconds >= deadline;
    }
};

const TestWatch = Watch(TestCondition);

const TestEvent = union(enum) {
    op: std.Io.Cancelable!u32,
    watch: std.Io.Cancelable!Outcome,
};

fn shortOperation(io: std.Io) std.Io.Cancelable!u32 {
    try io.sleep(.fromMicroseconds(200), .awake);
    return 7;
}

fn eventOperation(io: std.Io, done: *std.Io.Event) std.Io.Cancelable!u32 {
    try done.wait(io);
    return 9;
}

const SignalCounter = struct {
    var count: std.atomic.Value(u32) = .init(0);
    var previous: std.posix.Sigaction = undefined;

    fn handler(_: std.posix.SIG) callconv(.c) void {
        _ = count.fetchAdd(1, .monotonic);
    }

    fn install() void {
        count.store(0, .monotonic);
        const act: std.posix.Sigaction = .{
            .handler = .{ .handler = handler },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(.IO, &act, &previous);
    }

    fn uninstall() u32 {
        std.posix.sigaction(.IO, &previous, null);
        return count.load(.monotonic);
    }
};

fn skipWithoutSignals() error{SkipZigTest}!void {
    if (builtin.single_threaded or std.posix.Sigaction == void or builtin.target.os.tag == .windows) {
        return error.SkipZigTest;
    }
}

const EndRound = enum { finish, cancel };

fn raceRounds(io: std.Io, rounds: usize, end: EndRound) !void {
    var flag = std.atomic.Value(bool).init(false);
    for (0..rounds) |_| {
        var watch: TestWatch = .{};
        var buffer: [2]TestEvent = undefined;
        var select: std.Io.Select(TestEvent) = .init(io, &buffer);
        try select.concurrent(.watch, TestWatch.run, .{ &watch, io, TestCondition{ .flag = &flag } });
        select.concurrent(.op, shortOperation, .{io}) catch |err| {
            watch.finish(&select);
            return err;
        };
        const event = select.await() catch |err| {
            watch.stop(io);
            while (select.cancel()) |_| {}
            return err;
        };
        switch (end) {
            .finish => watch.finish(&select),
            .cancel => while (select.cancel()) |_| {},
        }
        try std.testing.expectEqual(@as(u32, 7), try event.op);
    }
}

test "finish after the operation wins sends no cancellation signal" {
    try skipWithoutSignals();
    SignalCounter.install();
    const result = raceRounds(std.testing.io, 200, .finish);
    const signals = SignalCounter.uninstall();
    try result;
    try std.testing.expectEqual(@as(u32, 0), signals);
}

test "cancelling a running watch signals its worker thread" {
    try skipWithoutSignals();
    SignalCounter.install();
    const result = raceRounds(std.testing.io, 50, .cancel);
    const signals = SignalCounter.uninstall();
    try result;
    try std.testing.expect(signals > 0);
}

test "watch reports cancellation and leaves the operation to finish" {
    const io = std.testing.io;
    var flag = std.atomic.Value(bool).init(true);
    var done: std.Io.Event = .unset;
    var watch: TestWatch = .{};
    var buffer: [2]TestEvent = undefined;
    var select: std.Io.Select(TestEvent) = .init(io, &buffer);
    try select.concurrent(.watch, TestWatch.run, .{ &watch, io, TestCondition{ .flag = &flag } });
    try select.concurrent(.op, eventOperation, .{ io, &done });

    try std.testing.expectEqual(Outcome.cancelled, try (try select.await()).watch);
    done.set(io);
    try std.testing.expectEqual(@as(u32, 9), try (try select.await()).op);
    try std.testing.expect(select.cancel() == null);
}

test "watch reports a passed deadline" {
    const io = std.testing.io;
    var flag = std.atomic.Value(bool).init(false);
    var watch: TestWatch = .{};
    const condition: TestCondition = .{ .flag = &flag, .deadline_ns = std.Io.Clock.awake.now(io).nanoseconds };
    try std.testing.expectEqual(Outcome.deadline, try TestWatch.run(&watch, io, condition));
}

test "stop makes a running watch return stopped" {
    const io = std.testing.io;
    var flag = std.atomic.Value(bool).init(false);
    var watch: TestWatch = .{};
    var buffer: [1]TestEvent = undefined;
    var select: std.Io.Select(TestEvent) = .init(io, &buffer);
    try select.concurrent(.watch, TestWatch.run, .{ &watch, io, TestCondition{ .flag = &flag } });
    io.sleep(.fromMilliseconds(12), .awake) catch {};
    watch.stop(io);
    try std.testing.expectEqual(Outcome.stopped, try (try select.await()).watch);
    try std.testing.expect(select.cancel() == null);
}
