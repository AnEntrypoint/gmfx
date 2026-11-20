const std = @import("std");

pub const Kind = enum {
    torn_tail_cut,
    opened_read_only,
    held_lines_dropped,
    index_healed,
    rebuild_swept,
    index_stale,
    snapshot_skipped,
};

pub const Event = struct {
    kind: Kind,
    session_id: []const u8,
    count: u64 = 0,
    offset: u64 = 0,
};

pub const Sink = struct {
    context: ?*anyopaque,
    emit: *const fn (context: ?*anyopaque, event: Event) void,
};

pub fn report(sink: ?Sink, event: Event) void {
    const s = sink orelse return;
    s.emit(s.context, event);
}

pub const Recorder = struct {
    gpa: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    io: std.Io,
    kinds: std.ArrayList(Kind) = .empty,

    pub fn sink(r: *Recorder) Sink {
        return .{ .context = r, .emit = record };
    }

    fn record(context: ?*anyopaque, event: Event) void {
        const r: *Recorder = @ptrCast(@alignCast(context.?));
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        r.kinds.append(r.gpa, event.kind) catch {};
    }

    pub fn count(r: *Recorder, kind: Kind) usize {
        var n: usize = 0;
        for (r.kinds.items) |k| {
            if (k == kind) n += 1;
        }
        return n;
    }

    pub fn deinit(r: *Recorder) void {
        r.kinds.deinit(r.gpa);
    }
};
