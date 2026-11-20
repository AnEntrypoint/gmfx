const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const tree_epoch = @import("tree_epoch.zig");

const Allocator = std.mem.Allocator;

pub const OperationKind = enum {
    write,
    edit,
};

pub const FileOperation = struct {
    kind: OperationKind,
    path: []u8,
    previous_content: ?[]u8,
    timestamp_ms: i64,
};

pub const UndoResult = union(enum) {
    restored: []const u8,
    deleted: []const u8,
    unavailable: []const u8,
    empty,
};

pub const RewindSummary = struct {
    restored: usize = 0,
    failed: usize = 0,
    skipped: usize = 0,
};

pub const rewind_notice_capacity: usize = 160;

pub fn rewindNotice(buf: *[rewind_notice_capacity]u8, summary: RewindSummary) []const u8 {
    if (summary.restored == 0 and summary.failed > 0) {
        return std.fmt.bufPrint(
            buf,
            "No files were restored: {d} files failed (backup missing, or the file could not be updated).",
            .{summary.failed},
        ) catch unreachable;
    }
    if (summary.skipped > 0) {
        return std.fmt.bufPrint(
            buf,
            "Restored the code, but skipped {d} files that are symlinks or hard links.",
            .{summary.skipped},
        ) catch unreachable;
    }
    if (summary.failed > 0) {
        return std.fmt.bufPrint(
            buf,
            "Restored {d} files; {d} files failed (backup missing, or the file could not be updated).",
            .{ summary.restored, summary.failed },
        ) catch unreachable;
    }
    if (summary.restored == 0) return "No tracked file edits to restore since that prompt.";
    return std.fmt.bufPrint(buf, "Restored {d} files to before that prompt.", .{summary.restored}) catch unreachable;
}

fn pathIsLinked(absolute_path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io_mod.getIo(), absolute_path, .{ .follow_symlinks = false }) catch return false;
    if (stat.kind == .sym_link) return true;
    return stat.kind == .file and stat.nlink > 1;
}

pub const ChangeTracker = struct {
    stack: std.ArrayList(FileOperation) = .empty,

    const max_stack_size: usize = 100;

    pub fn deinit(self: *ChangeTracker, alloc: Allocator) void {
        for (self.stack.items) |op| freeOperation(alloc, op);
        self.stack.deinit(alloc);
    }

    pub fn clear(self: *ChangeTracker, alloc: Allocator) void {
        for (self.stack.items) |op| freeOperation(alloc, op);
        self.stack.clearRetainingCapacity();
    }

    pub fn pushOperation(self: *ChangeTracker, alloc: Allocator, op: FileOperation) !void {
        if (self.stack.items.len >= max_stack_size) {
            freeOperation(alloc, self.stack.items[0]);
            _ = self.stack.orderedRemove(0);
        }
        try self.stack.append(alloc, op);
    }

    pub fn undoLast(self: *ChangeTracker, alloc: Allocator) UndoResult {
        if (self.stack.items.len == 0) return .empty;

        const op = self.stack.pop().?;

        switch (op.kind) {
            .write, .edit => {
                if (op.previous_content) |content| {
                    defer alloc.free(content);
                    restoreContent(alloc, op.path, content) catch |err| {
                        traceUnavailable(op, "restore_content", err);
                        return .{ .unavailable = op.path };
                    };
                    tree_epoch.bump();
                    return .{ .restored = op.path };
                }

                std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), op.path) catch |err| {
                    if (err != error.FileNotFound) {
                        traceUnavailable(op, "delete_created", err);
                        return .{ .unavailable = op.path };
                    }
                };
                tree_epoch.bump();
                return .{ .deleted = op.path };
            },
        }
    }

    pub fn rewindSince(self: *ChangeTracker, alloc: Allocator, since_ms: i64) RewindSummary {
        var summary: RewindSummary = .{};
        while (self.stack.items.len > 0) {
            const newest = self.stack.items[self.stack.items.len - 1];
            if (newest.timestamp_ms < since_ms) break;
            if (pathIsLinked(newest.path)) {
                freeOperation(alloc, self.stack.pop().?);
                summary.skipped += 1;
                continue;
            }
            switch (self.undoLast(alloc)) {
                .restored, .deleted => |path| {
                    alloc.free(path);
                    summary.restored += 1;
                },
                .unavailable => |path| {
                    alloc.free(path);
                    summary.failed += 1;
                },
                .empty => break,
            }
        }
        return summary;
    }

    fn restoreContent(alloc: Allocator, absolute_path: []const u8, content: []const u8) !void {
        try io_mod.writeFileAtomic(alloc, absolute_path, content);
    }

    fn freeOperation(alloc: Allocator, op: FileOperation) void {
        alloc.free(op.path);
        if (op.previous_content) |content| alloc.free(content);
    }
};

fn traceUnavailable(
    op: FileOperation,
    stage: []const u8,
    err: anyerror,
) void {
    var path_buf: [256]u8 = undefined;
    const path = debug_trace.terminalPreview(path_buf[0..], op.path);
    debug_trace.eventf(
        "undo",
        "undo_unavailable",
        .{},
        "kind={s} path={s} stage={s} error={s}",
        .{ @tagName(op.kind), path, stage, @errorName(err) },
    );
}

fn tmpPath(alloc: Allocator, dir: std.Io.Dir, name: []const u8) ![]u8 {
    const root = try io_mod.dirRealpathAlloc(alloc, dir, "");
    defer alloc.free(root);
    return std.Io.Dir.path.join(alloc, &.{ root, name });
}

fn writeAbsolute(path: []const u8, content: []const u8) !void {
    var file = try std.Io.Dir.createFileAbsolute(io_mod.getIo(), path, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), content);
}

fn readAbsolute(alloc: Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, 1024 * 1024);
}

fn expectMissing(path: []const u8) !void {
    if (std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{})) |file| {
        file.close(io_mod.getIo());
        return error.FileStillExists;
    } else |_| {}
}

const FileSizeLimitGuard = struct {
    saved_limit: std.posix.rlimit,
    saved_action: std.posix.Sigaction,

    fn restore(self: FileSizeLimitGuard) void {
        std.posix.setrlimit(.FSIZE, self.saved_limit) catch {};
        std.posix.sigaction(std.posix.SIG.XFSZ, &self.saved_action, null);
    }
};

fn limitFileSizeForTest(bytes: u64, fail_after_signal: bool) !FileSizeLimitGuard {
    var saved_action: std.posix.Sigaction = std.mem.zeroes(std.posix.Sigaction);
    std.posix.sigaction(std.posix.SIG.XFSZ, &.{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    }, &saved_action);
    errdefer std.posix.sigaction(std.posix.SIG.XFSZ, &saved_action, null);
    if (fail_after_signal) return error.InjectedSetupFailure;

    const saved_limit = try std.posix.getrlimit(.FSIZE);
    try std.posix.setrlimit(.FSIZE, .{ .cur = bytes, .max = saved_limit.max });
    return .{ .saved_limit = saved_limit, .saved_action = saved_action };
}

fn expectSignalHandlerEqual(expected: std.posix.Sigaction, actual: std.posix.Sigaction) !void {
    try std.testing.expectEqual(expected.handler.handler, actual.handler.handler);
}

test "file size limit guard restores SIGXFSZ after normal use" {
    if (builtin.target.os.tag != .linux and builtin.target.os.tag != .macos) return error.SkipZigTest;

    var original: std.posix.Sigaction = std.mem.zeroes(std.posix.Sigaction);
    std.posix.sigaction(std.posix.SIG.XFSZ, &.{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    }, &original);
    defer std.posix.sigaction(std.posix.SIG.XFSZ, &original, null);

    var expected: std.posix.Sigaction = std.mem.zeroes(std.posix.Sigaction);
    std.posix.sigaction(std.posix.SIG.XFSZ, null, &expected);
    const guard = try limitFileSizeForTest(4096, false);
    guard.restore();

    var actual: std.posix.Sigaction = std.mem.zeroes(std.posix.Sigaction);
    std.posix.sigaction(std.posix.SIG.XFSZ, null, &actual);
    try expectSignalHandlerEqual(expected, actual);
}

test "file size limit setup restores SIGXFSZ on failure" {
    if (builtin.target.os.tag != .linux and builtin.target.os.tag != .macos) return error.SkipZigTest;

    var original: std.posix.Sigaction = std.mem.zeroes(std.posix.Sigaction);
    std.posix.sigaction(std.posix.SIG.XFSZ, &.{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    }, &original);
    defer std.posix.sigaction(std.posix.SIG.XFSZ, &original, null);

    var expected: std.posix.Sigaction = std.mem.zeroes(std.posix.Sigaction);
    std.posix.sigaction(std.posix.SIG.XFSZ, null, &expected);
    try std.testing.expectError(error.InjectedSetupFailure, limitFileSizeForTest(4096, true));

    var actual: std.posix.Sigaction = std.mem.zeroes(std.posix.Sigaction);
    std.posix.sigaction(std.posix.SIG.XFSZ, null, &actual);
    try expectSignalHandlerEqual(expected, actual);
}

test "undoLast returns empty on an initially empty stack" {
    const alloc = std.testing.allocator;
    var tracker: ChangeTracker = .{};
    defer tracker.deinit(alloc);

    try std.testing.expect(tracker.undoLast(alloc) == .empty);
}

test "clear releases operations and leaves the tracker empty" {
    const alloc = std.testing.allocator;
    var tracker: ChangeTracker = .{};
    defer tracker.deinit(alloc);

    try tracker.pushOperation(alloc, .{
        .kind = .edit,
        .path = try alloc.dupe(u8, "/workspace/a.txt"),
        .previous_content = try alloc.dupe(u8, "before"),
        .timestamp_ms = 1,
    });

    tracker.clear(alloc);

    try std.testing.expectEqual(@as(usize, 0), tracker.stack.items.len);
    try std.testing.expect(tracker.undoLast(alloc) == .empty);

    try tracker.pushOperation(alloc, .{
        .kind = .write,
        .path = try alloc.dupe(u8, "/workspace/reused.txt"),
        .previous_content = null,
        .timestamp_ms = 2,
    });
    try std.testing.expectEqual(@as(usize, 1), tracker.stack.items.len);
    try std.testing.expectEqualStrings("/workspace/reused.txt", tracker.stack.items[0].path);
}

test "pushOperation evicts the oldest operation with stable ordering" {
    const alloc = std.testing.allocator;
    var tracker: ChangeTracker = .{};
    defer tracker.deinit(alloc);

    for (0..ChangeTracker.max_stack_size + 1) |i| {
        try tracker.pushOperation(alloc, .{
            .kind = .write,
            .path = try alloc.print("/tracked/file-{d}", .{i}),
            .previous_content = null,
            .timestamp_ms = @intCast(i),
        });
    }

    try std.testing.expectEqual(ChangeTracker.max_stack_size, tracker.stack.items.len);
    try std.testing.expectEqualStrings("/tracked/file-1", tracker.stack.items[0].path);
    try std.testing.expectEqualStrings("/tracked/file-100", tracker.stack.items[tracker.stack.items.len - 1].path);
}

test "rewindSince restores every tracked edit made at or after the prompt and keeps older ones" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const older = try tmpPath(alloc, tmp.dir, "older.txt");
    defer alloc.free(older);
    const edited = try tmpPath(alloc, tmp.dir, "edited.txt");
    defer alloc.free(edited);
    const created = try tmpPath(alloc, tmp.dir, "created.txt");
    defer alloc.free(created);

    try writeAbsolute(older, "older after");
    try writeAbsolute(edited, "edited after");
    try writeAbsolute(created, "created after");
    var tracker: ChangeTracker = .{};
    defer tracker.deinit(alloc);
    try tracker.pushOperation(alloc, .{ .kind = .edit, .path = try alloc.dupe(u8, older), .previous_content = try alloc.dupe(u8, "older before"), .timestamp_ms = 10 });
    try tracker.pushOperation(alloc, .{ .kind = .edit, .path = try alloc.dupe(u8, edited), .previous_content = try alloc.dupe(u8, "edited before"), .timestamp_ms = 20 });
    try tracker.pushOperation(alloc, .{ .kind = .write, .path = try alloc.dupe(u8, created), .previous_content = null, .timestamp_ms = 30 });

    const summary = tracker.rewindSince(alloc, 20);

    try std.testing.expectEqual(RewindSummary{ .restored = 2 }, summary);
    try std.testing.expectEqual(@as(usize, 1), tracker.stack.items.len);
    const edited_content = try readAbsolute(alloc, edited);
    defer alloc.free(edited_content);
    try std.testing.expectEqualStrings("edited before", edited_content);
    const older_content = try readAbsolute(alloc, older);
    defer alloc.free(older_content);
    try std.testing.expectEqualStrings("older after", older_content);
    try expectMissing(created);
}

test "rewindSince skips a tracked path that became a symlink and leaves its target alone" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const target = try tmpPath(alloc, tmp.dir, "target.txt");
    defer alloc.free(target);
    const link = try tmpPath(alloc, tmp.dir, "link.txt");
    defer alloc.free(link);
    try writeAbsolute(target, "target content");
    try tmp.dir.symLink(io_mod.getIo(), "target.txt", "link.txt", .{ .is_directory = false });

    var tracker: ChangeTracker = .{};
    defer tracker.deinit(alloc);
    try tracker.pushOperation(alloc, .{ .kind = .edit, .path = try alloc.dupe(u8, link), .previous_content = try alloc.dupe(u8, "before"), .timestamp_ms = 5 });

    const summary = tracker.rewindSince(alloc, 0);

    try std.testing.expectEqual(RewindSummary{ .skipped = 1 }, summary);
    try std.testing.expectEqual(@as(usize, 0), tracker.stack.items.len);
    const target_content = try readAbsolute(alloc, target);
    defer alloc.free(target_content);
    try std.testing.expectEqualStrings("target content", target_content);
}

test "rewindNotice words each outcome of a code restore" {
    var buf: [rewind_notice_capacity]u8 = undefined;
    try std.testing.expectEqualStrings(
        "No files were restored: 3 files failed (backup missing, or the file could not be updated).",
        rewindNotice(&buf, .{ .failed = 3 }),
    );
    try std.testing.expectEqualStrings(
        "Restored the code, but skipped 2 files that are symlinks or hard links.",
        rewindNotice(&buf, .{ .restored = 4, .skipped = 2 }),
    );
    try std.testing.expectEqualStrings(
        "Restored 4 files; 1 files failed (backup missing, or the file could not be updated).",
        rewindNotice(&buf, .{ .restored = 4, .failed = 1 }),
    );
    try std.testing.expectEqualStrings(
        "No tracked file edits to restore since that prompt.",
        rewindNotice(&buf, .{}),
    );
    try std.testing.expectEqualStrings(
        "Restored 5 files to before that prompt.",
        rewindNotice(&buf, .{ .restored = 5 }),
    );
    const widest = rewindNotice(&buf, .{ .restored = std.math.maxInt(usize), .failed = std.math.maxInt(usize) });
    try std.testing.expect(widest.len <= rewind_notice_capacity);
}

test "undoLast restores previous content for write and edit operations" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(alloc, tmp.dir, "restore.txt");
    defer alloc.free(path);
    defer std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), path) catch {};

    try writeAbsolute(path, "modified");
    var tracker: ChangeTracker = .{};
    defer tracker.deinit(alloc);

    try tracker.pushOperation(alloc, .{
        .kind = .write,
        .path = try alloc.dupe(u8, path),
        .previous_content = try alloc.dupe(u8, "original"),
        .timestamp_ms = 1,
    });

    const epoch_before_undo = tree_epoch.current();
    const result = tracker.undoLast(alloc);
    switch (result) {
        .restored => |restored_path| {
            defer alloc.free(restored_path);
            try std.testing.expectEqualStrings(path, restored_path);
        },
        else => return error.ExpectedRestore,
    }
    try std.testing.expect(tree_epoch.changedSince(epoch_before_undo));

    const content = try readAbsolute(alloc, path);
    defer alloc.free(content);
    try std.testing.expectEqualStrings("original", content);
}

test "undoLast deletes new write and edit operations" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(alloc, tmp.dir, "new.txt");
    defer alloc.free(path);
    defer std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), path) catch {};

    try writeAbsolute(path, "new content");
    var tracker: ChangeTracker = .{};
    defer tracker.deinit(alloc);

    try tracker.pushOperation(alloc, .{
        .kind = .edit,
        .path = try alloc.dupe(u8, path),
        .previous_content = null,
        .timestamp_ms = 1,
    });

    const result = tracker.undoLast(alloc);
    switch (result) {
        .deleted => |deleted_path| {
            defer alloc.free(deleted_path);
            try std.testing.expectEqualStrings(path, deleted_path);
        },
        else => return error.ExpectedDelete,
    }

    try expectMissing(path);
}

test "undoLast reports deleted for a new write when the file is already absent" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(alloc, tmp.dir, "already-absent.txt");
    defer alloc.free(path);

    var tracker: ChangeTracker = .{};
    defer tracker.deinit(alloc);

    try tracker.pushOperation(alloc, .{
        .kind = .write,
        .path = try alloc.dupe(u8, path),
        .previous_content = null,
        .timestamp_ms = 1,
    });

    const result = tracker.undoLast(alloc);
    switch (result) {
        .deleted => |deleted_path| {
            defer alloc.free(deleted_path);
            try std.testing.expectEqualStrings(path, deleted_path);
        },
        else => return error.ExpectedDelete,
    }

    try expectMissing(path);
}

test "undoLast reports unavailable when a new file cannot be deleted" {
    if (builtin.target.os.tag != .linux and builtin.target.os.tag != .macos) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "locked");
    const path = try tmpPath(alloc, tmp.dir, "locked/new.txt");
    defer alloc.free(path);
    try writeAbsolute(path, "new content");

    const dir_path = try tmpPath(alloc, tmp.dir, "locked");
    defer alloc.free(dir_path);
    const dir_path_z = try alloc.dupeSentinel(u8, dir_path, 0);
    defer alloc.free(dir_path_z);
    if (std.c.chmod(dir_path_z.ptr, 0o500) != 0) return error.SkipZigTest;
    defer _ = std.c.chmod(dir_path_z.ptr, 0o700);

    var tracker: ChangeTracker = .{};
    defer tracker.deinit(alloc);
    try tracker.pushOperation(alloc, .{
        .kind = .write,
        .path = try alloc.dupe(u8, path),
        .previous_content = null,
        .timestamp_ms = 1,
    });

    switch (tracker.undoLast(alloc)) {
        .unavailable => |reported_path| {
            defer alloc.free(reported_path);
            try std.testing.expectEqualStrings(path, reported_path);
        },
        else => return error.ExpectedUnavailable,
    }
    try std.testing.expectEqual(@as(usize, 0), tracker.stack.items.len);

    const survived = try readAbsolute(alloc, path);
    defer alloc.free(survived);
    try std.testing.expectEqualStrings("new content", survived);
}

test "undoLast pops before filesystem restore failures, reports them, and does not create parents" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(alloc, tmp.dir, "missing-parent/file.txt");
    defer alloc.free(path);

    var tracker: ChangeTracker = .{};
    defer tracker.deinit(alloc);
    try tracker.pushOperation(alloc, .{
        .kind = .write,
        .path = try alloc.dupe(u8, path),
        .previous_content = try alloc.dupe(u8, "content"),
        .timestamp_ms = 1,
    });

    switch (tracker.undoLast(alloc)) {
        .unavailable => |reported| alloc.free(reported),
        else => return error.ExpectedUnavailable,
    }
    try std.testing.expectEqual(@as(usize, 0), tracker.stack.items.len);
    try expectMissing(path);

    try std.testing.expect(tracker.undoLast(alloc) == .empty);
}

test "undoLast leaves the original file intact when the restore write fails" {
    if (builtin.target.os.tag != .linux and builtin.target.os.tag != .macos) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(alloc, tmp.dir, "restore-target.txt");
    defer alloc.free(path);
    defer std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), path) catch {};

    const current = "bytes the user still has on disk";
    try writeAbsolute(path, current);

    const preimage = try alloc.alloc(u8, 64 * 1024);
    defer alloc.free(preimage);
    @memset(preimage, 'R');

    var tracker: ChangeTracker = .{};
    defer tracker.deinit(alloc);
    try tracker.pushOperation(alloc, .{
        .kind = .write,
        .path = try alloc.dupe(u8, path),
        .previous_content = try alloc.dupe(u8, preimage),
        .timestamp_ms = 1,
    });

    const file_size_guard = try limitFileSizeForTest(4096, false);
    defer file_size_guard.restore();

    switch (tracker.undoLast(alloc)) {
        .unavailable => |reported| alloc.free(reported),
        else => return error.ExpectedUnavailable,
    }

    const survived = try readAbsolute(alloc, path);
    defer alloc.free(survived);
    try std.testing.expectEqualStrings(current, survived);
}

test "undo refuses a file whose directory denies writes and leaves it intact" {
    if (builtin.target.os.tag != .linux and builtin.target.os.tag != .macos) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "locked");
    const path = try tmpPath(alloc, tmp.dir, "locked/file.txt");
    defer alloc.free(path);
    try writeAbsolute(path, "current bytes");

    const dir_path = try tmpPath(alloc, tmp.dir, "locked");
    defer alloc.free(dir_path);
    const dir_path_z = try alloc.dupeSentinel(u8, dir_path, 0);
    defer alloc.free(dir_path_z);
    if (std.c.chmod(dir_path_z.ptr, 0o500) != 0) return error.SkipZigTest;
    defer _ = std.c.chmod(dir_path_z.ptr, 0o700);

    var tracker: ChangeTracker = .{};
    defer tracker.deinit(alloc);
    try tracker.pushOperation(alloc, .{
        .kind = .edit,
        .path = try alloc.dupe(u8, path),
        .previous_content = try alloc.dupe(u8, "preimage bytes"),
        .timestamp_ms = 1,
    });

    switch (tracker.undoLast(alloc)) {
        .unavailable => |reported| alloc.free(reported),
        else => return error.ExpectedUnavailable,
    }
    const survived = try readAbsolute(alloc, path);
    defer alloc.free(survived);
    try std.testing.expectEqualStrings("current bytes", survived);
}

test "undo restore cannot be redirected by a symlink introduced after capture" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const recorded_path = try tmpPath(alloc, tmp.dir, "recorded.txt");
    defer alloc.free(recorded_path);
    const redirect_target = try tmpPath(alloc, tmp.dir, "redirect-target.txt");
    defer alloc.free(redirect_target);
    try writeAbsolute(recorded_path, "current bytes");
    try writeAbsolute(redirect_target, "must stay untouched");

    var tracker: ChangeTracker = .{};
    defer tracker.deinit(alloc);
    try tracker.pushOperation(alloc, .{
        .kind = .edit,
        .path = try alloc.dupe(u8, recorded_path),
        .previous_content = try alloc.dupe(u8, "preimage bytes"),
        .timestamp_ms = 1,
    });

    try std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), recorded_path);
    tmp.dir.symLink(std.testing.io, redirect_target, "recorded.txt", .{ .is_directory = false }) catch return error.SkipZigTest;

    switch (tracker.undoLast(alloc)) {
        .restored => |restored| alloc.free(restored),
        else => return error.ExpectedRestore,
    }

    const restored_stat = try tmp.dir.statFile(io_mod.getIo(), "recorded.txt", .{ .follow_symlinks = false });
    try std.testing.expectEqual(std.Io.File.Kind.file, restored_stat.kind);
    const restored = try readAbsolute(alloc, recorded_path);
    defer alloc.free(restored);
    try std.testing.expectEqualStrings("preimage bytes", restored);
    const untouched = try readAbsolute(alloc, redirect_target);
    defer alloc.free(untouched);
    try std.testing.expectEqualStrings("must stay untouched", untouched);
}

test "a locked directory plus a failing write never leaves a half-replaced file" {
    if (builtin.target.os.tag != .linux and builtin.target.os.tag != .macos) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "locked");
    const path = try tmpPath(alloc, tmp.dir, "locked/file.txt");
    defer alloc.free(path);

    const current = "the bytes the user has right now";
    try writeAbsolute(path, current);

    const preimage = try alloc.alloc(u8, 64 * 1024);
    defer alloc.free(preimage);
    @memset(preimage, 'R');

    var tracker: ChangeTracker = .{};
    defer tracker.deinit(alloc);
    try tracker.pushOperation(alloc, .{
        .kind = .edit,
        .path = try alloc.dupe(u8, path),
        .previous_content = try alloc.dupe(u8, preimage),
        .timestamp_ms = 1,
    });

    const dir_path = try tmpPath(alloc, tmp.dir, "locked");
    defer alloc.free(dir_path);
    const dir_path_z = try alloc.dupeSentinel(u8, dir_path, 0);
    defer alloc.free(dir_path_z);
    if (std.c.chmod(dir_path_z.ptr, 0o500) != 0) return error.SkipZigTest;
    defer _ = std.c.chmod(dir_path_z.ptr, 0o700);

    const file_size_guard = try limitFileSizeForTest(4096, false);
    defer file_size_guard.restore();

    switch (tracker.undoLast(alloc)) {
        .unavailable => |reported| alloc.free(reported),
        else => return error.ExpectedUnavailable,
    }

    const survived = try readAbsolute(alloc, path);
    defer alloc.free(survived);
    try std.testing.expectEqualStrings(current, survived);
}
