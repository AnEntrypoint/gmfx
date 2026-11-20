const std = @import("std");

pub const not_active_message = "tower mode is not active — only the user can enable it (with /tower on), never the agent. Ask the user to turn tower mode on, then drive the tower protocol.";
pub const main_agent_only_message = "Tower orchestration tools are only supported by the main agent.";

pub const max_base_bytes: usize = 255;

var active: bool = false;
var pinned_base_bytes: [max_base_bytes]u8 = undefined;
var pinned_base_len: usize = 0;

pub fn isActive() bool {
    return active;
}

pub fn enter() void {
    active = true;
}

pub fn exit() void {
    active = false;
    pinned_base_len = 0;
}

pub fn enterOnBase(base: []const u8) error{TowerBaseTooLong}!void {
    if (base.len == 0 or base.len > max_base_bytes) return error.TowerBaseTooLong;
    @memcpy(pinned_base_bytes[0..base.len], base);
    pinned_base_len = base.len;
    active = true;
}

pub fn pinnedBase() ?[]const u8 {
    if (pinned_base_len == 0) return null;
    return pinned_base_bytes[0..pinned_base_len];
}

test "Tower mode is inactive until the user enters it" {
    exit();
    try std.testing.expect(!isActive());
    enter();
    try std.testing.expect(isActive());
    exit();
    try std.testing.expect(!isActive());
}

test "a base given with /tower <base> is kept for the next TowerInit until tower mode is left" {
    exit();
    try std.testing.expect(pinnedBase() == null);
    try enterOnBase("release/1.2");
    try std.testing.expect(isActive());
    try std.testing.expectEqualStrings("release/1.2", pinnedBase().?);
    enter();
    try std.testing.expectEqualStrings("release/1.2", pinnedBase().?);
    try std.testing.expectError(error.TowerBaseTooLong, enterOnBase(""));
    exit();
    try std.testing.expect(pinnedBase() == null);
}
