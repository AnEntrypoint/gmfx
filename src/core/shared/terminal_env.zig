const std = @import("std");
const io_mod = @import("io.zig");

pub fn noColorValue(value: ?[]const u8) bool {
    const set = value orelse return false;
    return set.len > 0;
}

pub fn dumbTerminalValue(value: ?[]const u8) bool {
    const term = value orelse return false;
    return std.mem.eql(u8, term, "dumb");
}

pub fn noColor() bool {
    return noColorValue(io_mod.getenv("NO_COLOR"));
}

pub fn dumbTerminal() bool {
    return dumbTerminalValue(io_mod.getenv("TERM"));
}

pub fn colorDisabled() bool {
    return noColor() or dumbTerminal();
}

test "NO_COLOR counts only when it is set to something" {
    try std.testing.expect(noColorValue("1"));
    try std.testing.expect(noColorValue("0"));
    try std.testing.expect(!noColorValue(""));
    try std.testing.expect(!noColorValue(null));
}

test "only TERM=dumb is a dumb terminal" {
    try std.testing.expect(dumbTerminalValue("dumb"));
    try std.testing.expect(!dumbTerminalValue("xterm-256color"));
    try std.testing.expect(!dumbTerminalValue("dumb-ish"));
    try std.testing.expect(!dumbTerminalValue(null));
}
