const std = @import("std");
const io_mod = @import("../shared/io.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const ContentHash = types.ContentHash;

pub const ViewRange = struct {
    start_line: usize = 1,
    tail_lines: ?usize = null,
    column_offset: usize = 0,
    line_count: ?usize = null,
    max_chars: usize = 0,

    pub fn eql(self: ViewRange, other: ViewRange) bool {
        return self.start_line == other.start_line and
            optionalEql(self.tail_lines, other.tail_lines) and
            self.column_offset == other.column_offset and
            optionalEql(self.line_count, other.line_count) and
            self.max_chars == other.max_chars;
    }

    fn optionalEql(a: ?usize, b: ?usize) bool {
        if (a == null or b == null) return a == null and b == null;
        return a.? == b.?;
    }
};

pub const ServedView = struct {
    range: ViewRange,
    step: u64,
};

pub const Record = struct {
    mtime_ns: i128,
    content_hash: ContentHash,
    model_view_covers_full_file: bool,
    snapshot_covers_full_file: bool,
    size_bytes: u64 = 0,
    served: ?ServedView = null,

    pub fn servedUnchanged(self: Record, mtime_ns: i128, size_bytes: u64, content_hash: ContentHash, range: ViewRange) ?ServedView {
        const served = self.served orelse return null;
        if (!self.snapshot_covers_full_file) return null;
        if (self.mtime_ns != mtime_ns or self.size_bytes != size_bytes) return null;
        if (!std.mem.eql(u8, &self.content_hash, &content_hash)) return null;
        if (!served.range.eql(range)) return null;
        return served;
    }
};

pub const ReadTracker = struct {
    alloc: Allocator = std.heap.c_allocator,
    entries: std.StringHashMapUnmanaged(Record) = .empty,
    lock: std.Io.Mutex = .init,
    step: u64 = 0,

    pub fn init(alloc: Allocator) ReadTracker {
        return .{ .alloc = alloc };
    }

    pub fn record(self: *ReadTracker, path: []const u8, value: Record) Allocator.Error!void {
        self.lock.lockUncancelable(io_mod.getIo());
        defer self.lock.unlock(io_mod.getIo());

        if (self.entries.getPtr(path)) |existing| {
            existing.* = value;
            return;
        }
        const owned_path = try self.alloc.dupe(u8, path);
        errdefer self.alloc.free(owned_path);
        try self.entries.put(self.alloc, owned_path, value);
    }

    pub fn lookup(self: *ReadTracker, path: []const u8) ?Record {
        self.lock.lockUncancelable(io_mod.getIo());
        defer self.lock.unlock(io_mod.getIo());
        return self.entries.get(path);
    }

    pub fn beginStep(self: *ReadTracker) u64 {
        self.lock.lockUncancelable(io_mod.getIo());
        defer self.lock.unlock(io_mod.getIo());
        self.step += 1;
        return self.step;
    }

    pub fn currentStep(self: *ReadTracker) u64 {
        self.lock.lockUncancelable(io_mod.getIo());
        defer self.lock.unlock(io_mod.getIo());
        return self.step;
    }

    pub fn forget(self: *ReadTracker, path: []const u8) void {
        self.lock.lockUncancelable(io_mod.getIo());
        defer self.lock.unlock(io_mod.getIo());
        const removed = self.entries.fetchRemove(path) orelse return;
        self.alloc.free(removed.key);
    }

    pub fn forgetServedViews(self: *ReadTracker) void {
        self.lock.lockUncancelable(io_mod.getIo());
        defer self.lock.unlock(io_mod.getIo());
        var values = self.entries.valueIterator();
        while (values.next()) |value| value.served = null;
    }

    pub fn deinit(self: *ReadTracker) void {
        var keys = self.entries.keyIterator();
        while (keys.next()) |key| self.alloc.free(key.*);
        self.entries.deinit(self.alloc);
        self.* = .{ .alloc = self.alloc };
    }
};

pub fn contentHash(bytes: []const u8) ContentHash {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(bytes);
    return hasher.finalResult();
}

test "ReadTracker records, looks up, overwrites, and frees owned keys" {
    const alloc = std.testing.allocator;
    var tracker = ReadTracker.init(alloc);
    defer tracker.deinit();

    const first = Record{
        .mtime_ns = 10,
        .content_hash = contentHash("first"),
        .model_view_covers_full_file = true,
        .snapshot_covers_full_file = true,
    };
    try tracker.record("/tmp/file.txt", first);

    const stored_first = tracker.lookup("/tmp/file.txt").?;
    try std.testing.expectEqual(@as(i128, 10), stored_first.mtime_ns);
    try std.testing.expectEqualSlices(u8, &first.content_hash, &stored_first.content_hash);
    try std.testing.expect(stored_first.model_view_covers_full_file);
    try std.testing.expect(stored_first.snapshot_covers_full_file);

    const second = Record{
        .mtime_ns = 20,
        .content_hash = contentHash("second"),
        .model_view_covers_full_file = false,
        .snapshot_covers_full_file = false,
    };
    try tracker.record("/tmp/file.txt", second);

    const stored_second = tracker.lookup("/tmp/file.txt").?;
    try std.testing.expectEqual(@as(i128, 20), stored_second.mtime_ns);
    try std.testing.expectEqualSlices(u8, &second.content_hash, &stored_second.content_hash);
    try std.testing.expect(!stored_second.model_view_covers_full_file);
    try std.testing.expect(!stored_second.snapshot_covers_full_file);
}

test "ReadTracker lookup returns null for unread paths" {
    var tracker = ReadTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try std.testing.expect(tracker.lookup("/tmp/missing.txt") == null);
}

test "contentHash distinguishes empty and non-empty content" {
    const empty = contentHash("");
    const filled = contentHash("x");

    try std.testing.expect(!std.mem.eql(u8, &empty, &filled));
    try std.testing.expectEqualSlices(u8, &empty, &contentHash(""));
}

fn servedRecord(range: ViewRange, step: u64) Record {
    return .{
        .mtime_ns = 10,
        .content_hash = contentHash("body"),
        .model_view_covers_full_file = true,
        .snapshot_covers_full_file = true,
        .size_bytes = 4,
        .served = .{ .range = range, .step = step },
    };
}

test "Record servedUnchanged answers only for the same file state and the same range" {
    const range = ViewRange{ .max_chars = 100 };
    const stored = servedRecord(range, 3);

    try std.testing.expectEqual(@as(u64, 3), stored.servedUnchanged(10, 4, contentHash("body"), range).?.step);
    try std.testing.expect(stored.servedUnchanged(11, 4, contentHash("body"), range) == null);
    try std.testing.expect(stored.servedUnchanged(10, 5, contentHash("body"), range) == null);
    try std.testing.expect(stored.servedUnchanged(10, 4, contentHash("edit"), range) == null);
    try std.testing.expect(stored.servedUnchanged(10, 4, contentHash("body"), .{ .start_line = 2, .max_chars = 100 }) == null);
    try std.testing.expect(stored.servedUnchanged(10, 4, contentHash("body"), .{ .line_count = 5, .max_chars = 100 }) == null);
    try std.testing.expect(stored.servedUnchanged(10, 4, contentHash("body"), .{ .tail_lines = 5, .max_chars = 100 }) == null);
    try std.testing.expect(stored.servedUnchanged(10, 4, contentHash("body"), .{ .column_offset = 1, .max_chars = 100 }) == null);
    try std.testing.expect(stored.servedUnchanged(10, 4, contentHash("body"), .{ .max_chars = 50 }) == null);

    var capped = stored;
    capped.snapshot_covers_full_file = false;
    try std.testing.expect(capped.servedUnchanged(10, 4, contentHash("body"), range) == null);

    var unserved = stored;
    unserved.served = null;
    try std.testing.expect(unserved.servedUnchanged(10, 4, contentHash("body"), range) == null);
}

test "ReadTracker forgetServedViews keeps file records and drops every served view" {
    var tracker = ReadTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.record("/tmp/a.txt", servedRecord(.{}, 1));
    try tracker.record("/tmp/b.txt", servedRecord(.{}, 2));
    tracker.forgetServedViews();

    try std.testing.expect(tracker.lookup("/tmp/a.txt").?.served == null);
    try std.testing.expect(tracker.lookup("/tmp/b.txt").?.served == null);
    try std.testing.expect(tracker.lookup("/tmp/a.txt").?.model_view_covers_full_file);
}

test "ReadTracker forget removes one path and beginStep counts upward" {
    var tracker = ReadTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.record("/tmp/a.txt", servedRecord(.{}, 1));
    try tracker.record("/tmp/b.txt", servedRecord(.{}, 1));
    tracker.forget("/tmp/a.txt");
    tracker.forget("/tmp/missing.txt");

    try std.testing.expect(tracker.lookup("/tmp/a.txt") == null);
    try std.testing.expect(tracker.lookup("/tmp/b.txt") != null);
    try std.testing.expectEqual(@as(u64, 1), tracker.beginStep());
    try std.testing.expectEqual(@as(u64, 2), tracker.beginStep());
}

test "ReadTracker default value is usable without init" {
    var tracker: ReadTracker = .{ .alloc = std.testing.allocator };
    defer tracker.deinit();

    try tracker.record("/tmp/a.txt", servedRecord(.{}, 1));
    try std.testing.expect(tracker.lookup("/tmp/a.txt") != null);
}
