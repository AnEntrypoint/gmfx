const std = @import("std");
const io_mod = @import("io.zig");
const debug_trace = @import("debug_trace.zig");

pub const stale_after_ns: i128 = 24 * std.time.ns_per_hour;

pub const Naming = struct {
    prefix: []const u8,
    owner: *const fn (unprefixed_name: []const u8) ?std.posix.pid_t,
};

pub fn ownerNamedByPid(unprefixed_name: []const u8) ?std.posix.pid_t {
    return std.fmt.parseInt(std.posix.pid_t, unprefixed_name, 10) catch null;
}

pub fn ownerMarkedBeforeDash(unprefixed_name: []const u8) ?std.posix.pid_t {
    if (unprefixed_name.len == 0 or unprefixed_name[0] != 'p') return null;
    const dash = std.mem.findScalar(u8, unprefixed_name, '-') orelse return null;
    return std.fmt.parseInt(std.posix.pid_t, unprefixed_name[1..dash], 10) catch null;
}

fn ownerIsRunning(owner: std.posix.pid_t) bool {
    if (owner <= 0) return false;
    std.posix.kill(owner, @fromBackingInt(@intCast(0))) catch |err| return err != error.ProcessNotFound;
    return true;
}

pub fn removeStaleDirs(parent: std.Io.Dir, naming: Naming, now_ns: i128) usize {
    const io = io_mod.getIo();
    var removed: usize = 0;
    var entries = parent.iterate();
    while (entries.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (!std.mem.startsWith(u8, entry.name, naming.prefix)) continue;
        if (naming.owner(entry.name[naming.prefix.len..])) |owner| {
            if (ownerIsRunning(owner)) continue;
        }
        const stat = parent.statFile(io, entry.name, .{ .follow_symlinks = false }) catch continue;
        if (stat.kind != .directory) continue;
        if (now_ns - stat.mtime.nanoseconds < stale_after_ns) continue;
        parent.deleteTree(io, entry.name) catch |err| {
            debug_trace.logf("core", "event=stale_temp_dir_left name={s} err={s}", .{ entry.name, @errorName(err) });
            continue;
        };
        removed += 1;
    }
    return removed;
}

pub fn removeStaleDirsAt(parent_path: []const u8, naming: Naming) usize {
    var parent = std.Io.Dir.openDirAbsolute(io_mod.getIo(), parent_path, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch return 0;
    defer parent.close(io_mod.getIo());
    return removeStaleDirs(parent, naming, io_mod.nanoTimestamp());
}

const test_naming: Naming = .{ .prefix = "fx-kept-", .owner = ownerMarkedBeforeDash };

fn dirExists(parent: std.Io.Dir, name: []const u8) bool {
    _ = parent.statFile(io_mod.getIo(), name, .{}) catch return false;
    return true;
}

test "stale temp sweep removes a day-old folder whose owner is gone and keeps the rest" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = io_mod.getIo();
    const permissions = std.Io.File.Permissions.fromMode(0o700);
    var own_name_buffer: [64]u8 = undefined;
    const own_name = try std.mem.print(&own_name_buffer, "fx-kept-p{d}-0000000000000001", .{std.c.getpid()});
    try tmp.dir.createDir(io, own_name, permissions);
    try tmp.dir.createDir(io, "fx-kept-p2147483646-0000000000000002", permissions);
    try tmp.dir.createDir(io, "fx-kept-0123456789abcdef", permissions);
    try tmp.dir.createDir(io, "fx-other-p2147483646-0000000000000003", permissions);
    var inner = try tmp.dir.createFile(io, "fx-kept-p2147483646-0000000000000002/image-1.bin", .{});
    inner.close(io);

    const now_ns = io_mod.nanoTimestamp();
    try std.testing.expectEqual(@as(usize, 0), removeStaleDirs(tmp.dir, test_naming, now_ns + stale_after_ns - std.time.ns_per_hour));
    try std.testing.expect(dirExists(tmp.dir, "fx-kept-p2147483646-0000000000000002"));

    try std.testing.expectEqual(@as(usize, 2), removeStaleDirs(tmp.dir, test_naming, now_ns + stale_after_ns + std.time.ns_per_hour));
    try std.testing.expect(dirExists(tmp.dir, own_name));
    try std.testing.expect(!dirExists(tmp.dir, "fx-kept-p2147483646-0000000000000002"));
    try std.testing.expect(!dirExists(tmp.dir, "fx-kept-0123456789abcdef"));
    try std.testing.expect(dirExists(tmp.dir, "fx-other-p2147483646-0000000000000003"));
}

test "stale temp sweep reads the owner from a pid name and from a marked name" {
    try std.testing.expectEqual(@as(?std.posix.pid_t, 4242), ownerNamedByPid("4242"));
    try std.testing.expectEqual(@as(?std.posix.pid_t, null), ownerNamedByPid("4242.log"));
    try std.testing.expectEqual(@as(?std.posix.pid_t, 4242), ownerMarkedBeforeDash("p4242-0123456789abcdef"));
    try std.testing.expectEqual(@as(?std.posix.pid_t, null), ownerMarkedBeforeDash("0123456789abcdef"));
}
