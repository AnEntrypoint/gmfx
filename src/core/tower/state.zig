const std = @import("std");

const Allocator = std.mem.Allocator;

pub const format_version: u32 = 1;
pub const max_state_bytes: usize = 16 * 1024 * 1024;

pub const Task = struct {
    text: []const u8,
    done: bool = false,
    dropped: ?bool = null,
};

pub const LastRebase = struct {
    fromCommit: []const u8,
    toCommit: []const u8,
};

pub const Mission = struct {
    id: []const u8,
    title: []const u8,
    slug: []const u8,
    kind: []const u8 = "build",
    scope: []const []const u8 = &.{},
    branch: []const u8,
    worktree: []const u8,
    spawnBase: ?[]const u8 = null,
    deps: []const []const u8 = &.{},
    lastRebase: ?LastRebase = null,
    status: []const u8 = "planned",
    owner: ?[]const u8 = null,
    context: ?[]const u8 = null,
    tasks: []Task = &.{},
    notes: []const []const u8 = &.{},
    blockers: []const []const u8 = &.{},
};

pub const RosterEntry = struct {
    name: []const u8,
    agentId: []const u8,
    sessionId: ?[]const u8 = null,
    kind: []const u8,
    missionId: ?[]const u8 = null,
    reviewTarget: ?[]const u8 = null,
    reviewMissionId: ?[]const u8 = null,
    worktree: ?[]const u8 = null,
    branch: ?[]const u8 = null,
    spawnedAt: []const u8,
    lastInboxReadAt: ?[]const u8 = null,
    inboxAckIds: ?[]const []const u8 = null,
    diedAt: ?[]const u8 = null,
    deathStatus: ?[]const u8 = null,
    deathReason: ?[]const u8 = null,
};

pub const Roster = struct {
    agents: []RosterEntry = &.{},
};

pub const State = struct {
    version: u32 = format_version,
    base: []const u8,
    mode: []const u8 = "branch",
    createdAt: []const u8,
    recoveredAt: ?[]const u8 = null,
    sessionId: ?[]const u8 = null,
    inboxAckIds: ?[]const []const u8 = null,
    roster: Roster = .{},
    missions: []Mission = &.{},

    pub fn findMission(self: State, id: []const u8) ?*Mission {
        for (self.missions) |*mission| {
            if (std.mem.eql(u8, mission.id, id)) return mission;
        }
        return null;
    }
};

pub fn encode(alloc: Allocator, state: State) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try std.json.Stringify.value(state, .{ .emit_null_optional_fields = false }, &out.writer);
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

pub fn decode(arena: Allocator, bytes: []const u8) !State {
    return std.json.parseFromSliceLeaky(State, arena, bytes, .{ .ignore_unknown_fields = true });
}

test "Tower state round-trips missions, tasks and roster" {
    const alloc = std.testing.allocator;
    var tasks = [_]Task{.{ .text = "write tests" }};
    var missions = [_]Mission{.{
        .id = "M1",
        .title = "Parser",
        .slug = "parser",
        .branch = "feat/parser",
        .worktree = ".tower/worktrees/wt-1",
        .tasks = &tasks,
    }};
    const state = State{
        .base = "main",
        .createdAt = "2026-05-01T00:00:00.000Z",
        .missions = &missions,
    };
    const bytes = try encode(alloc, state);
    defer alloc.free(bytes);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const decoded = try decode(arena_state.allocator(), bytes);
    try std.testing.expectEqualStrings("main", decoded.base);
    try std.testing.expectEqual(@as(usize, 1), decoded.missions.len);
    try std.testing.expectEqualStrings("feat/parser", decoded.missions[0].branch);
    try std.testing.expectEqualStrings("write tests", decoded.missions[0].tasks[0].text);
    try std.testing.expect(decoded.findMission("M1") != null);
    try std.testing.expect(decoded.findMission("M9") == null);
}
