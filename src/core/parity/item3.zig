const std = @import("std");

pub fn json(alloc: std.mem.Allocator, args: []const []const u8) ![]const u8 {
    _ = args;
    return try std.fmt.allocPrint(alloc, "{{\"item\":3,\"ok\":true,\"status\":\"stub\"}}", .{});
}
