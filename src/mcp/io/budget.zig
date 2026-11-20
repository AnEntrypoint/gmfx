const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const spare_min = 64 * 1024;

pub const Read = struct {
    held: usize = 0,
    counted: usize = 0,
    large: bool = false,
    node: std.DoublyLinkedList.Node = .{},
};

pub const Budget = struct {
    mutex: Io.Mutex = .init,
    room: Io.Condition = .init,
    line: std.DoublyLinkedList = .{},
    used: usize = 0,
    max: usize,
    allowance: usize = 64 * 1024,
    large: ?*Read = null,
    spare: ?[]u8 = null,

    pub fn deinit(b: *Budget, gpa: Allocator) void {
        if (b.spare) |s| gpa.free(s);
        b.spare = null;
    }

    pub fn take(b: *Budget, io: Io, n: usize) Io.Cancelable!void {
        try b.mutex.lock(io);
        defer b.mutex.unlock(io);
        var me: std.DoublyLinkedList.Node = .{};
        b.line.append(&me);
        defer {
            b.line.remove(&me);

            b.room.broadcast(io);
        }
        while (b.line.first != &me or (b.used != 0 and b.used + n > b.max)) try b.room.wait(io, &b.mutex);
        b.used += n;
    }

    pub fn copy(b: *Budget, io: Io, gpa: Allocator, bytes: []const u8) Io.Cancelable!?[]u8 {
        try b.take(io, bytes.len);
        if (bytes.len >= spare_min) if (b.swap(io, null)) |s| {
            if (gpa.resize(s, bytes.len)) {
                const out = s.ptr[0..bytes.len];
                @memcpy(out, bytes);
                return out;
            }
            gpa.free(s);
        };
        return gpa.dupe(u8, bytes) catch {
            b.give(io, bytes.len);
            return null;
        };
    }

    pub fn recycle(b: *Budget, io: Io, gpa: Allocator, bytes: []u8) void {
        if (bytes.len < spare_min) return gpa.free(bytes);
        b.mutex.lockUncancelable(io);
        const keep = if (b.spare) |s| bytes.len >= s.len else true;
        const out = if (keep) b.spare else bytes;
        if (keep) b.spare = bytes;
        b.mutex.unlock(io);
        if (out) |o| gpa.free(o);
    }

    fn swap(b: *Budget, io: Io, next: ?[]u8) ?[]u8 {
        b.mutex.lockUncancelable(io);
        defer b.mutex.unlock(io);
        const old = b.spare;
        b.spare = next;
        return old;
    }

    pub fn give(b: *Budget, io: Io, n: usize) void {
        if (n == 0) return;
        b.mutex.lockUncancelable(io);
        defer b.mutex.unlock(io);
        b.used -= n;
        b.room.broadcast(io);
    }

    pub fn grow(b: *Budget, io: Io, r: *Read, held: usize) Io.Cancelable!void {
        if (held <= r.held) return;
        if (held <= b.allowance) {
            r.held = held;
            return;
        }
        try b.mutex.lock(io);
        defer b.mutex.unlock(io);
        if (!r.large) {
            b.line.append(&r.node);
            defer {
                b.line.remove(&r.node);
                b.room.broadcast(io);
            }
            while (b.line.first != &r.node or b.large != null) try b.room.wait(io, &b.mutex);
            b.large = r;
            r.large = true;
        }
        const more = held - @max(r.held, b.allowance);
        while (b.used + more > b.max) try b.room.wait(io, &b.mutex);
        b.used += more;
        r.counted += more;
        r.held = held;
    }

    pub fn post(b: *Budget, io: Io, r: *Read, len: usize) Io.Cancelable!void {
        try b.mutex.lock(io);
        defer b.mutex.unlock(io);
        if (r.large) {
            while (b.used - r.counted + len > b.max) try b.room.wait(io, &b.mutex);
            b.used = b.used - r.counted + len;
            b.large = null;
        } else {
            b.line.append(&r.node);
            defer b.line.remove(&r.node);
            while (b.line.first != &r.node or b.used + len + b.reserve() > b.max) try b.room.wait(io, &b.mutex);
            b.used += len;
        }
        r.* = .{};
        b.room.broadcast(io);
    }

    pub fn drop(b: *Budget, io: Io, r: *Read) void {
        if (r.large) {
            b.mutex.lockUncancelable(io);
            defer b.mutex.unlock(io);
            b.used -= r.counted;
            b.large = null;
            b.room.broadcast(io);
        }
        r.* = .{};
    }

    fn reserve(b: *const Budget) usize {
        return if (b.large != null) 2 * b.allowance else 0;
    }

    pub fn adopt(b: *Budget, io: Io, gpa: Allocator, list: *std.ArrayList(u8)) void {
        const s = b.swap(io, null) orelse return;
        if (s.len <= list.capacity) return b.recycle(io, gpa, s);
        @memcpy(s[0..list.items.len], list.items);
        const len = list.items.len;
        list.deinit(gpa);
        list.* = .fromOwnedSlice(s);
        list.items.len = len;
    }
};

const testing = std.testing;

fn takeThenMark(b: *Budget, n: usize, done: *std.atomic.Value(bool)) Io.Cancelable!void {
    try b.take(testing.io, n);
    done.store(true, .release);
}

fn settle() void {
    Io.sleep(testing.io, .fromMilliseconds(50), .awake) catch {};
}

fn doneWithin(done: *std.atomic.Value(bool), ms: u32) bool {
    var waited: u32 = 0;
    while (!done.load(.acquire)) : (waited += 10) {
        if (waited >= ms) return false;
        Io.sleep(testing.io, .fromMilliseconds(10), .awake) catch {};
    }
    return true;
}

test "a message over the budget goes once nothing is held, and one that fits waits behind it" {
    var b: Budget = .{ .max = 16 };
    try b.take(testing.io, 8);
    var big_done: std.atomic.Value(bool) = .init(false);
    var big = try testing.io.concurrent(takeThenMark, .{ &b, 20, &big_done });
    defer big.cancel(testing.io) catch {};
    settle();
    var small_done: std.atomic.Value(bool) = .init(false);
    var small = try testing.io.concurrent(takeThenMark, .{ &b, 4, &small_done });
    defer small.cancel(testing.io) catch {};
    settle();

    try testing.expect(!big_done.load(.acquire) and !small_done.load(.acquire));
    b.give(testing.io, 8);
    try testing.expect(doneWithin(&big_done, 2_000));
    settle();
    try testing.expect(!small_done.load(.acquire));
    b.give(testing.io, 20);
    try testing.expect(doneWithin(&small_done, 2_000));
    try testing.expectEqual(@as(usize, 4), b.used);
}

test "a large message's buffer is reused for the next, and a small one is freed" {
    var counting: std.testing.FailingAllocator = .init(testing.allocator, .{});
    const gpa = counting.allocator();
    var b: Budget = .{ .max = 1 << 20 };
    defer b.deinit(gpa);
    const big: [200 * 1024]u8 = @splat('a');
    const first = (try b.copy(testing.io, gpa, &big)).?;
    b.give(testing.io, first.len);
    b.recycle(testing.io, gpa, first);
    try testing.expectEqual(@as(usize, 0), counting.deallocations);

    const next = (try b.copy(testing.io, gpa, big[0 .. 150 * 1024])).?;
    try testing.expectEqual(@as(usize, 1), counting.allocations);
    try testing.expectEqual(@as(usize, 150 * 1024), next.len);
    try testing.expect(b.spare == null);
    b.give(testing.io, next.len);
    b.recycle(testing.io, gpa, next);
    const small = (try b.copy(testing.io, gpa, "small")).?;
    try testing.expect(b.spare != null);
    b.give(testing.io, small.len);
    b.recycle(testing.io, gpa, small);
    try testing.expectEqual(@as(usize, 0), b.used);
}

test "a reader cancelled while it waits leaves the line, and the one behind it goes" {
    var b: Budget = .{ .max = 16 };
    try b.take(testing.io, 12);
    var first_done: std.atomic.Value(bool) = .init(false);
    var first = try testing.io.concurrent(takeThenMark, .{ &b, 16, &first_done });

    var first_ended = false;
    defer if (!first_ended) first.cancel(testing.io) catch {};
    settle();
    var second_done: std.atomic.Value(bool) = .init(false);
    var second = try testing.io.concurrent(takeThenMark, .{ &b, 4, &second_done });
    defer second.cancel(testing.io) catch {};
    settle();
    try testing.expect(!second_done.load(.acquire));
    first_ended = true;
    try testing.expectError(error.Canceled, first.cancel(testing.io));
    try testing.expect(doneWithin(&second_done, 2_000));
    try testing.expect(!first_done.load(.acquire));
    try testing.expectEqual(@as(usize, 16), b.used);
}

fn growThenMark(b: *Budget, r: *Read, held: usize, done: *std.atomic.Value(bool)) Io.Cancelable!void {
    try b.grow(testing.io, r, held);
    done.store(true, .release);
}

fn postThenMark(b: *Budget, r: *Read, len: usize, done: *std.atomic.Value(bool)) Io.Cancelable!void {
    try b.post(testing.io, r, len);
    done.store(true, .release);
}

test "a read within its allowance never waits, even with the budget full" {
    var b: Budget = .{ .max = 16, .allowance = 4 };
    try b.take(testing.io, 16);
    var r: Read = .{};
    try b.grow(testing.io, &r, 4);
    try testing.expectEqual(@as(usize, 16), b.used);
    try testing.expect(!r.large and b.large == null);
}

test "one reader at a time reads past its allowance, and the next waits until it posts" {
    var b: Budget = .{ .max = 64, .allowance = 4 };
    var first: Read = .{};
    try b.grow(testing.io, &first, 4);
    try b.grow(testing.io, &first, 8);
    try testing.expect(first.large and b.used == 4);
    var second: Read = .{};
    try b.grow(testing.io, &second, 4);
    var second_done: std.atomic.Value(bool) = .init(false);
    var task = try testing.io.concurrent(growThenMark, .{ &b, &second, 6, &second_done });
    defer task.cancel(testing.io) catch {};
    settle();
    try testing.expect(!second_done.load(.acquire));
    try b.post(testing.io, &first, 8);
    try testing.expect(doneWithin(&second_done, 2_000));
    try testing.expect(second.large);

    try testing.expectEqual(@as(usize, 10), b.used);
}

test "a small message leaves the large read room for its next step and its allowance" {
    var b: Budget = .{ .max = 16, .allowance = 2 };
    var large: Read = .{};
    try b.grow(testing.io, &large, 2);
    try b.grow(testing.io, &large, 4);
    try testing.expectEqual(@as(usize, 2), b.used);
    var small: Read = .{};

    for (0..5) |_| {
        try b.grow(testing.io, &small, 2);
        try b.post(testing.io, &small, 2);
    }

    try b.grow(testing.io, &small, 2);
    var small_done: std.atomic.Value(bool) = .init(false);
    var task = try testing.io.concurrent(postThenMark, .{ &b, &small, 2, &small_done });
    var task_ended = false;
    defer if (!task_ended) task.cancel(testing.io) catch {};
    settle();
    try testing.expect(!small_done.load(.acquire));

    try b.grow(testing.io, &large, 6);
    try b.post(testing.io, &large, 6);
    try testing.expectEqual(@as(usize, 16), b.used);
    settle();
    try testing.expect(!small_done.load(.acquire));

    b.give(testing.io, 2);
    try testing.expect(doneWithin(&small_done, 2_000));
    task_ended = true;
    try task.await(testing.io);
    try testing.expectEqual(@as(usize, 16), b.used);
}

test "a large read cancelled while it waits for room gives back what it counted, and the next takes the large read" {
    var b: Budget = .{ .max = 8, .allowance = 2 };
    try b.take(testing.io, 4);
    var first: Read = .{};
    try b.grow(testing.io, &first, 2);
    try b.grow(testing.io, &first, 4);
    try b.grow(testing.io, &first, 6);
    try testing.expectEqual(@as(usize, 8), b.used);
    var first_done: std.atomic.Value(bool) = .init(false);
    var task = try testing.io.concurrent(growThenMark, .{ &b, &first, 8, &first_done });
    var task_ended = false;
    defer if (!task_ended) task.cancel(testing.io) catch {};
    settle();
    try testing.expect(!first_done.load(.acquire));
    task_ended = true;
    try testing.expectError(error.Canceled, task.cancel(testing.io));
    b.drop(testing.io, &first);
    try testing.expectEqual(@as(usize, 4), b.used);
    try testing.expect(b.large == null);
    var second: Read = .{};
    try b.grow(testing.io, &second, 2);
    try b.grow(testing.io, &second, 4);
    try testing.expect(second.large);
    b.drop(testing.io, &second);
    try testing.expectEqual(@as(usize, 4), b.used);
}

test "the large read posts once there is room for its allowance too" {
    var b: Budget = .{ .max = 8, .allowance = 2 };
    try b.take(testing.io, 6);
    var large: Read = .{};
    try b.grow(testing.io, &large, 2);
    try b.grow(testing.io, &large, 4);
    try testing.expectEqual(@as(usize, 8), b.used);

    var done: std.atomic.Value(bool) = .init(false);
    var task = try testing.io.concurrent(postThenMark, .{ &b, &large, 4, &done });
    var task_ended = false;
    defer if (!task_ended) task.cancel(testing.io) catch {};
    settle();
    try testing.expect(!done.load(.acquire));
    b.give(testing.io, 6);
    try testing.expect(doneWithin(&done, 2_000));
    task_ended = true;
    try task.await(testing.io);
    try testing.expectEqual(@as(usize, 4), b.used);
}
