const std = @import("std");

pub const length = 26;

const alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

pub fn encode(now_ms: i64, random: [10]u8) [length]u8 {
    const time: u128 = @as(u64, @intCast(now_ms)) & 0xFFFF_FFFF_FFFF;
    var random_value: u128 = 0;
    for (random) |byte| random_value = (random_value << 8) | byte;
    const value = (time << 80) | random_value;
    var out: [length]u8 = undefined;
    for (&out, 0..) |*slot, index| {
        const shift: u7 = @intCast(5 * (length - 1 - index));
        slot.* = alphabet[@intCast((value >> shift) & 31)];
    }
    return out;
}

pub fn isId(text: []const u8) bool {
    if (text.len == 8) {
        for (text) |char| if (!std.ascii.isHex(char)) return false;
        return true;
    }
    if (text.len != length) return false;
    for (text) |char| {
        if (std.mem.indexOfScalar(u8, alphabet, std.ascii.toUpper(char)) == null) return false;
    }
    return true;
}

test "ulid encodes the timestamp into the leading characters" {
    const zero = @as([10]u8, @splat(0));
    const out = encode(1, zero);
    try std.testing.expectEqual(@as(u8, '0'), out[8]);
    try std.testing.expectEqual(@as(u8, '1'), out[9]);
    try std.testing.expectEqual(@as(u8, '0'), out[25]);
    try std.testing.expect(isId(&out));
}

test "ulid accepts only 26 Crockford characters or 8 hex digits" {
    try std.testing.expect(isId("01HZX3K9Y0ABCDEFGHJKMNPQRS"));
    try std.testing.expect(isId("deadbeef"));
    try std.testing.expect(!isId("01HZX3K9Y0ABCDEFGHJKMNPQRI"));
    try std.testing.expect(!isId("not-an-id"));
}
