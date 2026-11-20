const std = @import("std");
const tool_specs = @import("../../core/tooling/tool_specs.zig");

pub const bash_guard = @import("../../core/tower/bash_guard.zig");
pub const init = @import("init.zig");
pub const plan = @import("plan.zig");
pub const spawn = @import("spawn.zig");
pub const merge = @import("merge.zig");
pub const rebase = @import("rebase.zig");
pub const teardown = @import("teardown.zig");
pub const status = @import("status.zig");
pub const mission = @import("mission.zig");
pub const inbox = @import("inbox.zig");
pub const send = @import("send.zig");
pub const finding = @import("finding.zig");
pub const review = @import("review.zig");
pub const complete = @import("complete.zig");

pub const ToolSpec = tool_specs.ToolSpec;

pub const specs = [_]ToolSpec{
    init.spec,
    plan.spec,
    spawn.spec,
    mission.spec,
    status.spec,
    merge.spec,
    rebase.spec,
    teardown.spec,
    inbox.spec,
    send.spec,
    finding.spec,
    review.spec,
    complete.spec,
};

pub const names = [_][]const u8{
    "TowerInit",
    "TowerPlan",
    "TowerSpawn",
    "TowerMission",
    "TowerStatus",
    "TowerMerge",
    "TowerRebase",
    "TowerTeardown",
    "TowerInbox",
    "TowerSend",
    "TowerFinding",
    "TowerReview",
    "TowerComplete",
};

test "Tower index exports one spec per tool name in order" {
    try std.testing.expectEqual(names.len, specs.len);
    for (specs, names) |spec, name| {
        try std.testing.expectEqualStrings(name, spec.name);
    }
}
