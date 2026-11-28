const std = @import("std");
const io_mod = @import("../shared/io.zig");

pub var argv: []const []const u8 = &.{};

pub fn set(alloc: std.mem.Allocator, file: []const u8, rest: []const []const u8) !void {
    const exe = std.process.executablePathAlloc(io_mod.getIo(), alloc) catch try alloc.dupe(u8, "fx");
    const list = try alloc.alloc([]const u8, rest.len + 2);
    list[0] = exe;
    list[1] = file;
    @memcpy(list[2..], rest);
    argv = list;
}

pub fn blankShebang(text: []u8) void {
    if (text.len >= 2 and text[0] == '#' and text[1] == '!') {
        text[0] = '/';
        text[1] = '/';
    }
}

test "a shebang line becomes a line comment without moving later lines" {
    var text = "#!/usr/bin/env node\nconst a = 1\n".*;
    blankShebang(&text);
    try std.testing.expectEqualStrings("//usr/bin/env node\nconst a = 1\n", &text);
}
