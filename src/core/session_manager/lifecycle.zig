const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

const poll_interval_ms: i64 = 100;

pub const Event = enum { session_start, session_end, session_heartbeat };

pub const Notice = struct {
    event: Event,
    matcher_value: []const u8 = "",
    session_id: []const u8,
    workspace: []const u8,
    uptime_ms: u64 = 0,
};

pub const Sink = struct {
    context: *anyopaque,
    emit: *const fn (context: *anyopaque, notice: Notice) void,
    heartbeat_ms: ?u64 = null,
};

fn nowMs(io: std.Io) u64 {
    return std.math.cast(u64, std.Io.Timestamp.now(io, .real).toMilliseconds()) orelse 0;
}

pub const Heartbeat = struct {
    gpa: Allocator,
    io: std.Io,
    sink: Sink,
    session_id: []u8,
    workspace: []u8,
    interval_ms: u64,
    started_ms: u64,
    stopping: std.atomic.Value(bool) = .init(false),
    thread: std.Thread = undefined,

    pub fn start(gpa: Allocator, io: std.Io, sink: Sink, session_id: []const u8, workspace: []const u8, interval_ms: u64) !*Heartbeat {
        if (comptime builtin.single_threaded) return error.HeartbeatNeedsThreads;
        const self = try gpa.create(Heartbeat);
        errdefer gpa.destroy(self);
        const owned_id = try gpa.dupe(u8, session_id);
        errdefer gpa.free(owned_id);
        const owned_workspace = try gpa.dupe(u8, workspace);
        errdefer gpa.free(owned_workspace);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .sink = sink,
            .session_id = owned_id,
            .workspace = owned_workspace,
            .interval_ms = interval_ms,
            .started_ms = nowMs(io),
        };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    pub fn cancel(self: *Heartbeat) void {
        self.stopping.store(true, .release);
        self.thread.join();
        self.gpa.free(self.session_id);
        self.gpa.free(self.workspace);
        self.gpa.destroy(self);
    }

    fn run(self: *Heartbeat) void {
        var last_ms = self.started_ms;
        while (!self.stopping.load(.acquire)) {
            self.io.sleep(.fromMilliseconds(poll_interval_ms), .awake) catch return;
            const now = nowMs(self.io);
            if (now -| last_ms < self.interval_ms) continue;
            last_ms = now;
            if (self.stopping.load(.acquire)) return;
            self.sink.emit(self.sink.context, .{
                .event = .session_heartbeat,
                .session_id = self.session_id,
                .workspace = self.workspace,
                .uptime_ms = now -| self.started_ms,
            });
        }
    }
};

const testing = std.testing;

test "heartbeat emits session heartbeats with uptime until cancelled" {
    const Recorder = struct {
        mutex: std.Io.Mutex = .init,
        beats: usize = 0,
        last_uptime: u64 = 0,

        fn emit(context: *anyopaque, notice: Notice) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.mutex.lockUncancelable(testing.io);
            defer self.mutex.unlock(testing.io);
            if (notice.event != .session_heartbeat) return;
            self.beats += 1;
            self.last_uptime = notice.uptime_ms;
        }

        fn snapshot(self: *@This()) struct { beats: usize, last_uptime: u64 } {
            self.mutex.lockUncancelable(testing.io);
            defer self.mutex.unlock(testing.io);
            return .{ .beats = self.beats, .last_uptime = self.last_uptime };
        }
    };
    var recorder: Recorder = .{};
    const heartbeat = try Heartbeat.start(testing.allocator, testing.io, .{
        .context = &recorder,
        .emit = Recorder.emit,
    }, "session-1", "/w", 10);
    for (0..400) |_| {
        if (recorder.snapshot().beats >= 2) break;
        try testing.io.sleep(.fromMilliseconds(5), .awake);
    }
    heartbeat.cancel();
    const seen = recorder.snapshot();
    try testing.expect(seen.beats >= 2);
    try testing.expect(seen.last_uptime >= 10);
    const after_cancel = recorder.snapshot().beats;
    try testing.io.sleep(.fromMilliseconds(250), .awake);
    try testing.expectEqual(after_cancel, recorder.snapshot().beats);
}
