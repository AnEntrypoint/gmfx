const std = @import("std");

pub const Level = enum {
    debug,
    info,
    notice,
    warning,
    @"error",
    critical,
    alert,
    emergency,
};

pub fn parse(name: []const u8) ?Level {
    return std.meta.stringToEnum(Level, name);
}

test "every RFC 5424 level name parses and unknown names do not" {
    try std.testing.expectEqual(Level.debug, parse("debug").?);
    try std.testing.expectEqual(Level.@"error", parse("error").?);
    try std.testing.expectEqual(Level.emergency, parse("emergency").?);
    try std.testing.expect(parse("verbose") == null);
    try std.testing.expect(parse("") == null);
}
