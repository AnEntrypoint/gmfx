const std = @import("std");
const profiles = @import("../profiles/profiles.zig");

pub const name = profiles.tower_worker_name;

pub const role = profiles.tower_worker_prompt;

test "Tower profile names the tower worker and carries the handoff and protocol roles" {
    try std.testing.expectEqualStrings("tower-worker", name);
    try std.testing.expect(std.mem.find(u8, role, "Your final message is the entire handoff.") != null);
    try std.testing.expect(std.mem.find(u8, role, "TowerInbox") != null);
    try std.testing.expect(std.mem.startsWith(u8, role, "You are a subagent;"));
}
