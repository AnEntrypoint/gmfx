const std = @import("std");
const Allocator = std.mem.Allocator;

pub const max_listed = 5;

pub const Tracker = struct {
    gpa: Allocator,
    workspace_root: []const u8,
    paths: std.ArrayList([]u8) = .empty,

    pub fn deinit(self: *Tracker) void {
        for (self.paths.items) |path| self.gpa.free(path);
        self.paths.deinit(self.gpa);
    }

    pub fn record(self: *Tracker, path: []const u8) Allocator.Error!void {
        for (self.paths.items, 0..) |existing, i| {
            if (!std.mem.eql(u8, existing, path)) continue;
            const kept = self.paths.orderedRemove(i);
            try self.paths.insert(self.gpa, 0, kept);
            return;
        }
        const owned = try self.gpa.dupe(u8, path);
        errdefer self.gpa.free(owned);
        try self.paths.insert(self.gpa, 0, owned);
    }

    pub fn recent(self: *const Tracker) []const []u8 {
        return self.paths.items[0..@min(self.paths.items.len, max_listed)];
    }
};

pub fn formatHandoff(arena: Allocator, handoff: []const u8, edits: []const []u8) Allocator.Error![]const u8 {
    if (edits.len == 0) return handoff;
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, handoff);
    try out.appendSlice(arena, "\n\nRecently edited files, re-read them before relying on earlier reads:");
    for (edits) |path| {
        try out.appendSlice(arena, "\n- ");
        try out.appendSlice(arena, path);
    }
    return out.items;
}

test "a tracker lists the newest five distinct edited files first" {
    var tracker: Tracker = .{ .gpa = std.testing.allocator, .workspace_root = "/ws" };
    defer tracker.deinit();
    for ([_][]const u8{ "a", "b", "c", "d", "e", "f", "b" }) |path| try tracker.record(path);
    const listed = tracker.recent();
    try std.testing.expectEqual(@as(usize, 5), listed.len);
    try std.testing.expectEqualStrings("b", listed[0]);
    try std.testing.expectEqualStrings("f", listed[1]);
    try std.testing.expectEqualStrings("e", listed[2]);
    try std.testing.expectEqualStrings("d", listed[3]);
    try std.testing.expectEqualStrings("c", listed[4]);
}

test "a handoff lists recent edits after its text, and an empty list leaves it alone" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tracker: Tracker = .{ .gpa = std.testing.allocator, .workspace_root = "/ws" };
    defer tracker.deinit();
    try std.testing.expectEqualStrings("handoff", try formatHandoff(arena, "handoff", tracker.recent()));
    try tracker.record("src/a.zig");
    try tracker.record("src/b.zig");
    try std.testing.expectEqualStrings(
        "handoff\n\nRecently edited files, re-read them before relying on earlier reads:\n- src/b.zig\n- src/a.zig",
        try formatHandoff(arena, "handoff", tracker.recent()),
    );
}
