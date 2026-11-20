const std = @import("std");
const io_mod = @import("../shared/io.zig");
const session_layout = @import("session_layout.zig");

const Allocator = std.mem.Allocator;

pub const max_plan_bytes: usize = 1024 * 1024;
const plan_extension = ".md";

pub fn planFileName(alloc: Allocator, session_id: []const u8) ![]u8 {
    try session_layout.validateSessionId(session_id);
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ session_id, plan_extension });
}

pub fn read(alloc: Allocator, session_dir: *io_mod.VerifiedDir, session_id: []const u8) !?[]u8 {
    const name = try planFileName(alloc, session_id);
    defer alloc.free(name);
    var file = io_mod.openExistingReadOnlyRegularFile(session_dir.dir, name, .no_follow) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io_mod.getIo());
    return try io_mod.readFileToEnd(alloc, &file, max_plan_bytes);
}

pub fn write(alloc: Allocator, session_dir: *io_mod.VerifiedDir, session_id: []const u8, text: []const u8) !void {
    if (text.len > max_plan_bytes) return error.PlanTooLarge;
    const name = try planFileName(alloc, session_id);
    defer alloc.free(name);
    try io_mod.durableReplaceVerified(alloc, session_dir, name, text);
}

pub fn clear(alloc: Allocator, session_dir: *io_mod.VerifiedDir, session_id: []const u8) !void {
    const name = try planFileName(alloc, session_id);
    defer alloc.free(name);
    session_dir.dir.deleteFile(io_mod.getIo(), name) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

test "session plan file round trips and clears" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var dir = io_mod.VerifiedDir{ .dir = tmp.dir };

    try std.testing.expect((try read(alloc, &dir, "session_plan_a")) == null);
    try write(alloc, &dir, "session_plan_a", "# Plan\n- step one\n");
    const stored = (try read(alloc, &dir, "session_plan_a")).?;
    defer alloc.free(stored);
    try std.testing.expectEqualStrings("# Plan\n- step one\n", stored);

    const name = try planFileName(alloc, "session_plan_a");
    defer alloc.free(name);
    try std.testing.expectEqualStrings("session_plan_a.md", name);

    try clear(alloc, &dir, "session_plan_a");
    try std.testing.expect((try read(alloc, &dir, "session_plan_a")) == null);
    try clear(alloc, &dir, "session_plan_a");
}

test "session plan write replaces the file atomically" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var dir = io_mod.VerifiedDir{ .dir = tmp.dir };

    try write(alloc, &dir, "session_plan_b", "first draft");
    try write(alloc, &dir, "session_plan_b", "second draft");
    const stored = (try read(alloc, &dir, "session_plan_b")).?;
    defer alloc.free(stored);
    try std.testing.expectEqualStrings("second draft", stored);

    var entries: usize = 0;
    var iterator = tmp.dir.iterate();
    while (try iterator.next(io_mod.getIo())) |entry| {
        entries += 1;
        try std.testing.expectEqualStrings("session_plan_b.md", entry.name);
    }
    try std.testing.expectEqual(@as(usize, 1), entries);

    try std.testing.expectError(error.InvalidSessionId, write(alloc, &dir, "../escape", "x"));
    const oversized = try alloc.alloc(u8, max_plan_bytes + 1);
    defer alloc.free(oversized);
    @memset(oversized, 'a');
    try std.testing.expectError(error.PlanTooLarge, write(alloc, &dir, "session_plan_b", oversized));
}
