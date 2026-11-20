const std = @import("std");

pub noinline fn zeroAndFree(alloc: std.mem.Allocator, value: []u8) void {
    if (value.len == 0) return;
    std.crypto.secureZero(u8, @volatileCast(value));
    alloc.free(value);
}

test "zeroAndFree overwrites bytes before release" {
    var value = [_]u8{ 1, 2, 3 };
    std.crypto.secureZero(u8, @volatileCast(value[0..]));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0 }, &value);
}
