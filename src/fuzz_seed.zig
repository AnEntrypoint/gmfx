const std = @import("std");

pub fn slices(comptime seeds: anytype) [seeds.len][]const u8 {
    return comptime encoded: {
        var inputs: [seeds.len][]const u8 = undefined;
        for (&inputs, 0..) |*input, i| input.* = slice(seeds[i]);
        break :encoded inputs;
    };
}

fn slice(comptime bytes: []const u8) []const u8 {
    return comptime encoded: {
        var len: [4]u8 = undefined;
        std.mem.writeInt(u32, &len, bytes.len, .little);
        const input = len ++ bytes[0..bytes.len].*;
        break :encoded &input;
    };
}

test "a seed reads back through the fuzz input reader" {
    const inputs = slices(.{ "", "one", "split every field" });
    for (inputs, [_][]const u8{ "", "one", "split every field" }) |input, seed| {
        var smith: std.testing.Smith = .{ .in = input };
        var buffer: [32]u8 = undefined;
        try std.testing.expectEqualStrings(seed, buffer[0..smith.slice(&buffer)]);
    }
}
