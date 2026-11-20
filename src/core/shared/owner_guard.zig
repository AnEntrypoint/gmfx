const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("io.zig");

pub const guards_process_groups = builtin.target.os.tag == .linux;

const kills_watched_groups_once_the_owner_is_gone =
    \\trap '' INT HUP
    \\groups=
    \\while read -r change; do
    \\  case $change in
    \\    +*) groups="$groups ${change#+}" ;;
    \\    -*) kept=; for group in $groups; do [ "$group" = "${change#-}" ] || kept="$kept $group"; done; groups=$kept ;;
    \\  esac
    \\done
    \\[ -n "$groups" ] || exit 0
    \\for group in $groups; do kill -s TERM -- "-$group"; done
    \\sleep 0.1
    \\for group in $groups; do kill -s KILL -- "-$group"; done
;

pub const Guard = struct {
    mutex: std.Io.Mutex = .init,
    started: bool = false,
    owner_end: ?std.posix.fd_t = null,
    watcher: ?std.process.Child = null,

    pub fn watch(self: *Guard, group: std.posix.pid_t) void {
        self.tell('+', group);
    }

    pub fn release(self: *Guard, group: std.posix.pid_t) void {
        self.tell('-', group);
    }

    fn tell(self: *Guard, sign: u8, group: std.posix.pid_t) void {
        if (comptime !guards_process_groups) return;
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (!self.started) self.start(io);
        const fd = self.owner_end orelse return;
        var buffer: [16]u8 = undefined;
        const line = std.mem.print(&buffer, "{c}{d}\n", .{ sign, group }) catch return;
        if (std.c.write(fd, line.ptr, line.len) == line.len) return;
        self.abandonLocked(io);
    }

    fn start(self: *Guard, io: std.Io) void {
        self.started = true;
        const watcher = std.process.spawn(io, .{
            .argv = &.{ "/bin/sh", "-c", kills_watched_groups_once_the_owner_is_gone },
            .stdin = .pipe,
            .stdout = .ignore,
            .stderr = .ignore,
            .pgid = 0,
        }) catch return;
        self.watcher = watcher;
        self.owner_end = watcher.stdin.?.handle;
    }

    fn abandonLocked(self: *Guard, io: std.Io) void {
        if (self.watcher) |*watcher| watcher.kill(io);
        self.watcher = null;
        self.owner_end = null;
    }

    fn ownerGone(self: *Guard) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        var watcher = self.watcher orelse return;
        watcher.stdin.?.close(io);
        watcher.stdin = null;
        _ = watcher.wait(io) catch {};
        self.watcher = null;
        self.owner_end = null;
    }
};

var process_guard: Guard = .{};

pub fn watch(group: std.posix.pid_t) void {
    process_guard.watch(group);
}

pub fn release(group: std.posix.pid_t) void {
    process_guard.release(group);
}

fn spawnOwnGroup(script: []const u8) !std.process.Child {
    return std.process.spawn(io_mod.getIo(), .{
        .argv = &.{ "/bin/sh", "-c", script },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = 0,
    });
}

test "owner guard ends a watched process group once the owner is gone" {
    if (comptime !guards_process_groups) return error.SkipZigTest;
    var guard: Guard = .{};
    var child = try spawnOwnGroup("sleep 30 & sleep 30 & wait");
    guard.watch(child.id.?);
    const started_ms = io_mod.milliTimestamp();
    guard.ownerGone();
    const term = try child.wait(io_mod.getIo());
    try std.testing.expect(term == .signal);
    try std.testing.expect(io_mod.milliTimestamp() - started_ms < 10_000);
}

test "owner guard leaves a released process group running after the owner is gone" {
    if (comptime !guards_process_groups) return error.SkipZigTest;
    var guard: Guard = .{};
    var child = try spawnOwnGroup("sleep 1; exit 7");
    guard.watch(child.id.?);
    guard.release(child.id.?);
    guard.ownerGone();
    const term = try child.wait(io_mod.getIo());
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 7 }, term);
}
