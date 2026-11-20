const std = @import("std");
const state = @import("state.zig");

const Allocator = std.mem.Allocator;

pub fn missionsIndex(alloc: Allocator, st: state.State) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.print(alloc, "# Tower missions\n\nMode: {s} — Base: {s}\n\n", .{ st.mode, st.base });
    try out.appendSlice(alloc, "| ID | Mission | Branch | Worktree | Status | Owner |\n|---|---|---|---|---|---|\n");
    for (st.missions) |mission| {
        try out.print(alloc, "| {s} | {s} | {s} | {s} | {s} | {s} |\n", .{
            mission.id,
            mission.title,
            mission.branch,
            mission.worktree,
            mission.status,
            mission.owner orelse "-",
        });
    }
    return out.toOwnedSlice(alloc);
}

pub fn missionFile(alloc: Allocator, mission: state.Mission) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.print(alloc, "# Mission {s}: {s}\n\n", .{ mission.id, mission.title });
    try out.print(alloc, "| Branch | Worktree | Status | Scope | Owner |\n|---|---|---|---|---|\n| {s} | {s} | {s} | {s} | {s} |\n\n", .{
        mission.branch,
        mission.worktree,
        mission.status,
        try std.mem.join(alloc, ", ", mission.scope),
        mission.owner orelse "-",
    });
    if (mission.context) |context| try out.print(alloc, "## Context\n\n{s}\n\n", .{context});
    try out.appendSlice(alloc, "## Tasks\n\n");
    if (mission.tasks.len == 0) try out.appendSlice(alloc, "- [ ] (no tasks recorded)\n");
    for (mission.tasks) |task| {
        const mark: []const u8 = if (task.done) "[x]" else if (task.dropped == true) "[-]" else "[ ]";
        const suffix: []const u8 = if (task.dropped == true) " (dropped)" else "";
        try out.print(alloc, "- {s} {s}{s}\n", .{ mark, task.text, suffix });
    }
    try out.appendSlice(alloc, "\n## Dependencies\n\n");
    for (mission.deps) |dep| try out.print(alloc, "- {s}\n", .{dep});
    try out.appendSlice(alloc, "\n## Blockers\n\n");
    for (mission.blockers) |blocker| try out.print(alloc, "- {s}\n", .{blocker});
    try out.appendSlice(alloc, "\n## Notes\n\n");
    for (mission.notes) |note| try out.print(alloc, "- {s}\n", .{note});
    return out.toOwnedSlice(alloc);
}

test "Tower render lists missions in the index table" {
    const alloc = std.testing.allocator;
    var missions = [_]state.Mission{.{ .id = "M1", .title = "Parser", .slug = "parser", .branch = "feat/parser", .worktree = ".tower/worktrees/wt-1" }};
    const text = try missionsIndex(alloc, .{ .base = "main", .createdAt = "2026-05-01T00:00:00.000Z", .missions = &missions });
    defer alloc.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "| M1 | Parser | feat/parser | .tower/worktrees/wt-1 | planned | - |") != null);
}
