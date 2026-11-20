const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Entry = struct {
    id: []u8,
    label: []u8,
    detail: []u8,
};

pub const State = struct {
    active: bool = false,
    entries: std.ArrayList(Entry) = .empty,
    selected: usize = 0,
    window_start: usize = 0,

    pub fn open(self: *State, alloc: Allocator, rows: []const Row) Allocator.Error!void {
        self.close(alloc);
        errdefer self.close(alloc);
        for (rows) |row| {
            const entry: Entry = .{
                .id = try alloc.dupe(u8, row.id),
                .label = try alloc.dupe(u8, row.label),
                .detail = try alloc.dupe(u8, row.detail),
            };
            try self.entries.append(alloc, entry);
        }
        self.selected = 0;
        self.window_start = 0;
        self.active = true;
    }

    pub const Row = struct {
        id: []const u8,
        label: []const u8,
        detail: []const u8,
    };

    pub fn move(self: *State, delta: i32) void {
        if (!self.active or self.entries.items.len == 0) return;
        const count: i64 = @intCast(self.entries.items.len);
        self.selected = @intCast(@mod(@as(i64, @intCast(self.selected)) + delta, count));
    }

    pub fn selectedEntry(self: *const State) ?*const Entry {
        if (!self.active or self.entries.items.len == 0) return null;
        return &self.entries.items[self.selected];
    }

    pub fn close(self: *State, alloc: Allocator) void {
        for (self.entries.items) |entry| {
            alloc.free(entry.id);
            alloc.free(entry.label);
            alloc.free(entry.detail);
        }
        self.entries.deinit(alloc);
        self.* = .{};
    }
};

test "core.tasks_menu moves through tasks and wraps" {
    const alloc = std.testing.allocator;
    var menu: State = .{};
    defer menu.close(alloc);
    try menu.open(alloc, &.{
        .{ .id = "t1", .label = "t1  running  sleep 1", .detail = "t1\nstate: running" },
        .{ .id = "t2", .label = "t2  done  ls", .detail = "t2\nstate: done" },
    });
    try std.testing.expectEqualStrings("t1", menu.selectedEntry().?.id);
    menu.move(1);
    try std.testing.expectEqualStrings("t2", menu.selectedEntry().?.id);
    menu.move(1);
    try std.testing.expectEqualStrings("t1", menu.selectedEntry().?.id);
    menu.move(-1);
    try std.testing.expectEqualStrings("t2", menu.selectedEntry().?.id);
}

test "core.tasks_menu keeps the detail for the selected task and empties on close" {
    const alloc = std.testing.allocator;
    var menu: State = .{};
    defer menu.close(alloc);
    try std.testing.expect(menu.selectedEntry() == null);
    try menu.open(alloc, &.{.{ .id = "t9", .label = "t9  done  make", .detail = "t9\nstate: done\ncommand: make" }});
    try std.testing.expectEqualStrings("t9\nstate: done\ncommand: make", menu.selectedEntry().?.detail);
    menu.close(alloc);
    try std.testing.expect(!menu.active);
    try std.testing.expectEqual(@as(usize, 0), menu.entries.items.len);
}

test "core.tasks_menu with no rows has no selection" {
    const alloc = std.testing.allocator;
    var menu: State = .{};
    defer menu.close(alloc);
    try menu.open(alloc, &.{});
    try std.testing.expect(menu.active);
    try std.testing.expect(menu.selectedEntry() == null);
    menu.move(1);
    try std.testing.expect(menu.selectedEntry() == null);
}
