const std = @import("std");

extern "c" fn posix_openpt(flags: c_int) c_int;
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname(fd: c_int) ?[*:0]u8;

pub const Session = struct {
    child: std.process.Child,
    master: std.posix.fd_t,
};

pub fn spawn(io: std.Io, argv: []const []const u8) !Session {
    const master_flags = std.posix.O{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true, .NONBLOCK = true };
    const master = posix_openpt(@bitCast(master_flags));
    if (master < 0) return error.PtyUnavailable;
    errdefer _ = std.c.close(master);
    if (grantpt(master) != 0 or unlockpt(master) != 0) return error.PtyUnavailable;
    const slave_name = ptsname(master) orelse return error.PtyUnavailable;
    const slave = try std.posix.openatZ(std.posix.AT.FDCWD, slave_name, .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true }, 0);
    errdefer _ = std.c.close(slave);
    const slave_file = std.Io.File{ .handle = slave, .flags = .{ .nonblocking = false } };
    const child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .{ .file = slave_file },
        .stdout = .{ .file = slave_file },
        .stderr = .{ .file = slave_file },
    });
    _ = std.c.close(slave);
    return .{ .child = child, .master = master };
}

pub fn write(io: std.Io, master: std.posix.fd_t, bytes: []const u8) !void {
    const file = std.Io.File{ .handle = master, .flags = .{ .nonblocking = false } };
    try file.writeStreamingAll(io, bytes);
}

pub fn read(master: std.posix.fd_t, buffer: []u8) !usize {
    var fds = [_]std.posix.pollfd{.{ .fd = master, .events = std.posix.POLL.IN, .revents = 0 }};
    _ = try std.posix.poll(&fds, -1);
    return std.posix.read(master, buffer) catch |err| switch (err) {
        error.InputOutput => 0,
        else => return err,
    };
}
