const std = @import("std");
const cron_runtime = @import("../../cron/runtime.zig");
const ulid = @import("../../cron/ulid.zig");

const Allocator = std.mem.Allocator;

pub const Sink = struct {
    context: *anyopaque,
    submit_fn: *const fn (context: *anyopaque, text: []const u8) anyerror!void,
    persist_fn: *const fn (context: *anyopaque, line: []const u8) anyerror!void,

    pub fn submit(self: Sink, text: []const u8) anyerror!void {
        return self.submit_fn(self.context, text);
    }

    pub fn persist(self: Sink, line: []const u8) anyerror!void {
        return self.persist_fn(self.context, line);
    }
};

pub fn replayJournal(cron: *cron_runtime.Runtime, lines: []const []const u8) cron_runtime.ReplayError!void {
    for (lines) |line| try cron.replay(line);
}

pub fn tick(alloc: Allocator, cron: *cron_runtime.Runtime, sink: Sink, now_ms: i64, loop_running: bool) anyerror!usize {
    const fires = try cron.collectDue(alloc, now_ms, loop_running);
    defer cron_runtime.Runtime.freeFires(alloc, fires);

    var delivered: usize = 0;
    for (fires) |fire| {
        sink.submit(fire.text) catch continue;
        try cron.acknowledge(fire);
        delivered += 1;
    }

    const lines = try cron.drainJournal();
    defer freeLines(cron.alloc, lines);
    var persisted: usize = 0;
    while (persisted < lines.len) : (persisted += 1) {
        sink.persist(lines[persisted]) catch break;
    }
    try cron.retainJournal(lines[persisted..]);
    return delivered;
}

fn freeLines(alloc: Allocator, lines: [][]u8) void {
    for (lines) |line| alloc.free(line);
    alloc.free(lines);
}

const Recorder = struct {
    alloc: Allocator,
    submitted: std.ArrayList([]const u8) = .empty,
    persisted: std.ArrayList([]const u8) = .empty,
    reject_submit: bool = false,
    reject_persist: bool = false,

    fn submitFn(context: *anyopaque, text: []const u8) anyerror!void {
        const self: *Recorder = @ptrCast(@alignCast(context));
        if (self.reject_submit) return error.SubmitRejected;
        try self.submitted.append(self.alloc, try self.alloc.dupe(u8, text));
    }

    fn persistFn(context: *anyopaque, line: []const u8) anyerror!void {
        const self: *Recorder = @ptrCast(@alignCast(context));
        if (self.reject_persist) return error.NoOpenSession;
        try self.persisted.append(self.alloc, try self.alloc.dupe(u8, line));
    }

    fn sink(self: *Recorder) Sink {
        return .{ .context = self, .submit_fn = submitFn, .persist_fn = persistFn };
    }

    fn deinit(self: *Recorder) void {
        for (self.submitted.items) |text| self.alloc.free(text);
        self.submitted.deinit(self.alloc);
        for (self.persisted.items) |line| self.alloc.free(line);
        self.persisted.deinit(self.alloc);
    }
};

const created: i64 = 1_704_067_230_000;

fn addMinuteTask(cron: *cron_runtime.Runtime) !void {
    _ = try cron.add(ulid.encode(created, @as([10]u8, @splat(1))), "* * * * *", "check build", created, true);
}

test "cron tick delivers due fires, acknowledges them, and persists journal lines in order" {
    const alloc = std.testing.allocator;
    var cron = cron_runtime.Runtime.init(alloc, .{ .no_jitter = true });
    defer cron.deinit();
    try addMinuteTask(&cron);
    var recorder = Recorder{ .alloc = alloc };
    defer recorder.deinit();

    const delivered = try tick(alloc, &cron, recorder.sink(), created + 120_000, false);

    try std.testing.expectEqual(@as(usize, 1), delivered);
    try std.testing.expectEqual(@as(usize, 1), recorder.submitted.items.len);
    try std.testing.expect(std.mem.indexOf(u8, recorder.submitted.items[0], "<prompt>\ncheck build\n</prompt>") != null);
    try std.testing.expectEqual(@as(usize, 2), recorder.persisted.items.len);
    try std.testing.expect(std.mem.indexOf(u8, recorder.persisted.items[0], "cron.add") != null);
    try std.testing.expect(std.mem.indexOf(u8, recorder.persisted.items[1], "cron.cursor") != null);

    for (recorder.persisted.items) |line| alloc.free(line);
    recorder.persisted.clearRetainingCapacity();
    const again = try tick(alloc, &cron, recorder.sink(), created + 120_000, false);
    try std.testing.expectEqual(@as(usize, 0), again);
    try std.testing.expectEqual(@as(usize, 0), recorder.persisted.items.len);
}

test "cron tick keeps journal lines queued until a session can persist them" {
    const alloc = std.testing.allocator;
    var cron = cron_runtime.Runtime.init(alloc, .{ .no_jitter = true });
    defer cron.deinit();
    try addMinuteTask(&cron);
    var recorder = Recorder{ .alloc = alloc, .reject_persist = true };
    defer recorder.deinit();

    _ = try tick(alloc, &cron, recorder.sink(), created + 120_000, false);
    try std.testing.expectEqual(@as(usize, 0), recorder.persisted.items.len);

    recorder.reject_persist = false;
    const again = try tick(alloc, &cron, recorder.sink(), created + 120_000, false);
    try std.testing.expectEqual(@as(usize, 0), again);
    try std.testing.expectEqual(@as(usize, 2), recorder.persisted.items.len);
    try std.testing.expect(std.mem.indexOf(u8, recorder.persisted.items[0], "cron.add") != null);
    try std.testing.expect(std.mem.indexOf(u8, recorder.persisted.items[1], "cron.cursor") != null);
}

test "cron tick skips fires while the agent loop is running" {
    const alloc = std.testing.allocator;
    var cron = cron_runtime.Runtime.init(alloc, .{ .no_jitter = true });
    defer cron.deinit();
    try addMinuteTask(&cron);
    var recorder = Recorder{ .alloc = alloc };
    defer recorder.deinit();

    const delivered = try tick(alloc, &cron, recorder.sink(), created + 120_000, true);

    try std.testing.expectEqual(@as(usize, 0), delivered);
    try std.testing.expectEqual(@as(usize, 0), recorder.submitted.items.len);
}

test "cron tick keeps a fire unacknowledged when the submit is rejected" {
    const alloc = std.testing.allocator;
    var cron = cron_runtime.Runtime.init(alloc, .{ .no_jitter = true });
    defer cron.deinit();
    try addMinuteTask(&cron);
    var recorder = Recorder{ .alloc = alloc, .reject_submit = true };
    defer recorder.deinit();

    const delivered = try tick(alloc, &cron, recorder.sink(), created + 120_000, false);

    try std.testing.expectEqual(@as(usize, 0), delivered);
    try std.testing.expectEqual(@as(usize, 1), recorder.persisted.items.len);
    try std.testing.expect(std.mem.indexOf(u8, recorder.persisted.items[0], "cron.cursor") == null);
    const still_due = try cron.collectDue(alloc, created + 120_000, false);
    defer cron_runtime.Runtime.freeFires(alloc, still_due);
    try std.testing.expectEqual(@as(usize, 1), still_due.len);
}

test "cron replay restores journaled tasks before the first tick" {
    const alloc = std.testing.allocator;
    var source = cron_runtime.Runtime.init(alloc, .{ .no_jitter = true });
    defer source.deinit();
    try addMinuteTask(&source);
    var recorder = Recorder{ .alloc = alloc };
    defer recorder.deinit();
    _ = try tick(alloc, &source, recorder.sink(), created, true);

    var restored = cron_runtime.Runtime.init(alloc, .{ .no_jitter = true });
    defer restored.deinit();
    try replayJournal(&restored, recorder.persisted.items);

    try std.testing.expectEqual(@as(usize, 1), restored.list().len);
}
