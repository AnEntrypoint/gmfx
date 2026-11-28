const std = @import("std");

pub var argv: []const []const u8 = &.{};

pub fn set(alloc: std.mem.Allocator, file: []const u8, rest: []const []const u8) !void {
    const list = try alloc.alloc([]const u8, rest.len + 2);
    list[0] = "fx";
    list[1] = file;
    @memcpy(list[2..], rest);
    argv = list;
}
