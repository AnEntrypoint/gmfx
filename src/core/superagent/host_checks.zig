const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;

pub const default_min_free_mb: u64 = 512;

pub fn minFreeMb(configured: ?u64) u64 {
    return configured orelse default_min_free_mb;
}

pub fn availableKbIn(meminfo: []const u8) ?u64 {
    var lines = std.mem.splitScalar(u8, meminfo, '\n');
    while (lines.next()) |line| {
        const label = "MemAvailable:";
        if (!std.mem.startsWith(u8, line, label)) continue;
        var fields = std.mem.tokenizeAny(u8, line[label.len..], " \t");
        const amount = fields.next() orelse return null;
        return std.fmt.parseInt(u64, amount, 10) catch null;
    }
    return null;
}

pub const StartFacts = struct {
    available_kb: ?u64,
    min_free_mb: u64,
};

pub const StartAdmission = enum { admit, refuse_low_memory };

pub fn admitStart(facts: StartFacts) StartAdmission {
    if (facts.min_free_mb == 0) return .admit;
    const available = facts.available_kb orelse return .admit;
    return if (available / 1024 >= facts.min_free_mb) .admit else .refuse_low_memory;
}

pub fn childPidsIn(alloc: Allocator, children: []const u8, into: *std.ArrayList(i32)) !void {
    var fields = std.mem.tokenizeAny(u8, children, " \t\n");
    while (fields.next()) |field| {
        const pid = std.fmt.parseInt(i32, field, 10) catch continue;
        if (pid > 0) try into.append(alloc, pid);
    }
}

pub const JobProcess = enum { wait_on_it, own_process, not_a_process };

pub fn jobProcess(named: ?i32, own_pid: i32, is_alive: bool) JobProcess {
    const pid = named orelse return .not_a_process;
    if (pid <= 1) return .not_a_process;
    if (pid == own_pid) return .own_process;
    return if (is_alive) .wait_on_it else .not_a_process;
}

fn readSmallFile(path: [*:0]const u8, buffer: []u8) ?[]const u8 {
    if (comptime builtin.target.os.tag != .linux) return null;
    const linux = std.os.linux;
    const opened = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(opened) != .SUCCESS) return null;
    const fd: std.posix.fd_t = @intCast(opened);
    defer _ = linux.close(fd);
    var filled: usize = 0;
    while (filled < buffer.len) {
        const got = linux.read(fd, buffer[filled..].ptr, buffer.len - filled);
        switch (linux.errno(got)) {
            .SUCCESS => {
                if (got == 0) break;
                filled += got;
            },
            .INTR => continue,
            else => return null,
        }
    }
    return buffer[0..filled];
}

pub fn availableKb() ?u64 {
    var buffer: [8192]u8 = undefined;
    const text = readSmallFile("/proc/meminfo", &buffer) orelse return null;
    return availableKbIn(text);
}

pub fn ownChildPids(alloc: Allocator) ![]i32 {
    var pids: std.ArrayList(i32) = .empty;
    errdefer pids.deinit(alloc);
    if (comptime builtin.target.os.tag != .linux) return pids.toOwnedSlice(alloc);
    var dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), "/proc/self/task", .{ .iterate = true }) catch return pids.toOwnedSlice(alloc);
    defer dir.close(io_mod.getIo());
    var iterator = dir.iterate();
    while (iterator.next(io_mod.getIo()) catch null) |entry| {
        var path_buffer: [96]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buffer, "/proc/self/task/{s}/children\x00", .{entry.name}) catch continue;
        var buffer: [4096]u8 = undefined;
        const text = readSmallFile(@ptrCast(path.ptr), &buffer) orelse continue;
        try childPidsIn(alloc, text, &pids);
    }
    return pids.toOwnedSlice(alloc);
}

pub fn renderHostLine(alloc: Allocator, min_free_mb: u64) ![]u8 {
    const children = try ownChildPids(alloc);
    defer alloc.free(children);
    const available = availableKb();
    const admission = admitStart(.{ .available_kb = available, .min_free_mb = min_free_mb });
    if (available) |kb| {
        return std.fmt.allocPrint(alloc, "host memory_available_mb={d} min_free_mb={d} new_roots={s} child_processes={d}", .{
            kb / 1024,
            min_free_mb,
            if (admission == .admit) "admitted" else "refused",
            children.len,
        });
    }
    return std.fmt.allocPrint(alloc, "host memory_available_mb=unknown min_free_mb={d} new_roots=admitted child_processes={d}", .{ min_free_mb, children.len });
}

test "available memory is read from the MemAvailable line and nothing else" {
    const meminfo =
        \\MemTotal:       32768000 kB
        \\MemFree:         1024000 kB
        \\MemAvailable:    8192000 kB
        \\Buffers:          100000 kB
    ;
    try std.testing.expectEqual(@as(?u64, 8192000), availableKbIn(meminfo));
    try std.testing.expectEqual(@as(?u64, null), availableKbIn("MemTotal: 5 kB\nMemFree: 4 kB\n"));
    try std.testing.expectEqual(@as(?u64, null), availableKbIn("MemAvailable: lots kB\n"));
}

test "a new root is refused only when measured memory is under the floor, and a zero floor turns the check off" {
    try std.testing.expectEqual(StartAdmission.admit, admitStart(.{ .available_kb = 600 * 1024, .min_free_mb = 512 }));
    try std.testing.expectEqual(StartAdmission.admit, admitStart(.{ .available_kb = 512 * 1024, .min_free_mb = 512 }));
    try std.testing.expectEqual(StartAdmission.refuse_low_memory, admitStart(.{ .available_kb = 511 * 1024, .min_free_mb = 512 }));
    try std.testing.expectEqual(StartAdmission.admit, admitStart(.{ .available_kb = null, .min_free_mb = 512 }));
    try std.testing.expectEqual(StartAdmission.admit, admitStart(.{ .available_kb = 1, .min_free_mb = 0 }));
    try std.testing.expectEqual(@as(u64, 512), minFreeMb(null));
    try std.testing.expectEqual(@as(u64, 64), minFreeMb(64));
}

test "child process ids are read from a children line" {
    const alloc = std.testing.allocator;
    var pids: std.ArrayList(i32) = .empty;
    defer pids.deinit(alloc);
    try childPidsIn(alloc, "4242 77 x 0 9001 \n", &pids);
    try std.testing.expectEqualSlices(i32, &.{ 4242, 77, 9001 }, pids.items);
}

test "a job is waited on only when it names a live process that is not fx itself" {
    try std.testing.expectEqual(JobProcess.wait_on_it, jobProcess(4242, 100, true));
    try std.testing.expectEqual(JobProcess.not_a_process, jobProcess(4242, 100, false));
    try std.testing.expectEqual(JobProcess.own_process, jobProcess(100, 100, true));
    try std.testing.expectEqual(JobProcess.not_a_process, jobProcess(null, 100, true));
    try std.testing.expectEqual(JobProcess.not_a_process, jobProcess(1, 100, true));
}

test "the host's own memory and children can be read on linux" {
    if (comptime builtin.target.os.tag != .linux) return;
    const alloc = std.testing.allocator;
    try std.testing.expect(availableKb() != null);
    const children = try ownChildPids(alloc);
    defer alloc.free(children);
    const line = try renderHostLine(alloc, 0);
    defer alloc.free(line);
    try std.testing.expect(std.mem.find(u8, line, "new_roots=admitted") != null);
}
