const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Purpose = enum { theme, permission_mode, experiment, logout_provider };

pub const toggle_enabled_label = "enabled";
pub const toggle_disabled_label = "disabled";

pub const TitledChoices = struct {
    purpose: Purpose,
    title: []const u8,
    choices: []const []const u8,
    descriptions: []const []const u8,
    current_name: []const u8,
    highlighted_name: []const u8,
};

pub const State = struct {
    active: bool = false,
    purpose: Purpose = .theme,
    title: []const u8 = "",
    descriptions: []const []const u8 = &.{},
    choices: std.ArrayList([]u8) = .empty,
    toggle_labels: std.ArrayList([]const u8) = .empty,
    current: usize = 0,
    selected: usize = 0,
    window_start: usize = 0,

    pub fn open(self: *State, alloc: Allocator, choices: []const []const u8, current_name: []const u8) Allocator.Error!void {
        self.close(alloc);
        errdefer self.close(alloc);
        for (choices) |choice| try self.choices.append(alloc, try alloc.dupe(u8, choice));
        self.current = indexOf(self.choices.items, current_name) orelse 0;
        self.selected = self.current;
        self.window_start = 0;
        self.active = true;
    }

    pub fn openTitled(self: *State, alloc: Allocator, titled: TitledChoices) Allocator.Error!void {
        try self.open(alloc, titled.choices, titled.current_name);
        self.purpose = titled.purpose;
        self.title = titled.title;
        self.descriptions = titled.descriptions;
        self.selected = indexOf(self.choices.items, titled.highlighted_name) orelse self.current;
    }

    pub fn openToggles(self: *State, alloc: Allocator, purpose: Purpose, title: []const u8, names: []const []const u8, enabled: []const bool) Allocator.Error!void {
        try self.open(alloc, names, "");
        errdefer self.close(alloc);
        for (enabled) |on| try self.toggle_labels.append(alloc, if (on) toggle_enabled_label else toggle_disabled_label);
        self.purpose = purpose;
        self.title = title;
        self.descriptions = self.toggle_labels.items;
        self.current = self.choices.items.len;
        self.selected = 0;
    }

    pub fn selectedToggleEnabled(self: *const State) ?bool {
        if (!self.active or self.selected >= self.toggle_labels.items.len) return null;
        return std.mem.eql(u8, self.toggle_labels.items[self.selected], toggle_enabled_label);
    }

    pub fn move(self: *State, delta: i32) void {
        if (!self.active or self.choices.items.len == 0) return;
        const count: i64 = @intCast(self.choices.items.len);
        self.selected = @intCast(@mod(@as(i64, @intCast(self.selected)) + delta, count));
    }

    pub fn currentName(self: *const State) ?[]const u8 {
        if (!self.active or self.current >= self.choices.items.len) return null;
        return self.choices.items[self.current];
    }

    pub fn selectedName(self: *const State) ?[]const u8 {
        if (!self.active or self.choices.items.len == 0) return null;
        return self.choices.items[self.selected];
    }

    pub fn close(self: *State, alloc: Allocator) void {
        for (self.choices.items) |choice| alloc.free(choice);
        self.choices.deinit(alloc);
        self.toggle_labels.deinit(alloc);
        self.* = .{};
    }
};

fn indexOf(items: []const []u8, name: []const u8) ?usize {
    for (items, 0..) |item, index| {
        if (std.mem.eql(u8, item, name)) return index;
    }
    return null;
}

test "core.theme_menu moves through choices, wraps, and starts on the current theme" {
    const alloc = std.testing.allocator;
    var menu: State = .{};
    defer menu.close(alloc);
    try menu.open(alloc, &.{ "dark", "light", "ocean" }, "light");
    try std.testing.expect(menu.active);
    try std.testing.expectEqual(@as(usize, 1), menu.selected);
    try std.testing.expectEqualStrings("light", menu.selectedName().?);
    menu.move(1);
    try std.testing.expectEqualStrings("ocean", menu.selectedName().?);
    menu.move(1);
    try std.testing.expectEqualStrings("dark", menu.selectedName().?);
    menu.move(-1);
    try std.testing.expectEqualStrings("ocean", menu.selectedName().?);
}

test "core.theme_menu falls back to the first choice when the current theme is unknown" {
    const alloc = std.testing.allocator;
    var menu: State = .{};
    defer menu.close(alloc);
    try menu.open(alloc, &.{ "dark", "light" }, "missing-custom");
    try std.testing.expectEqual(@as(usize, 0), menu.current);
    try std.testing.expectEqualStrings("dark", menu.selectedName().?);
}

test "core.theme_menu closed has no selection and reopening replaces the list" {
    const alloc = std.testing.allocator;
    var menu: State = .{};
    defer menu.close(alloc);
    try std.testing.expect(menu.selectedName() == null);
    try menu.open(alloc, &.{ "dark", "light" }, "dark");
    menu.close(alloc);
    try std.testing.expect(!menu.active);
    try std.testing.expectEqual(@as(usize, 0), menu.choices.items.len);
    try menu.open(alloc, &.{"solo"}, "solo");
    try std.testing.expectEqualStrings("solo", menu.selectedName().?);
}

test "core.theme_menu titled choices keep the current row and start on the highlighted one" {
    const alloc = std.testing.allocator;
    var menu: State = .{};
    defer menu.close(alloc);
    try menu.openTitled(alloc, .{
        .purpose = .permission_mode,
        .title = "Select permission mode",
        .choices = &.{ "Always Ask", "Ask When Needed", "Never Ask" },
        .descriptions = &.{ "first", "second", "third" },
        .current_name = "Always Ask",
        .highlighted_name = "Never Ask",
    });
    try std.testing.expectEqual(Purpose.permission_mode, menu.purpose);
    try std.testing.expectEqualStrings("Always Ask", menu.currentName().?);
    try std.testing.expectEqualStrings("Never Ask", menu.selectedName().?);
    try std.testing.expectEqualStrings("third", menu.descriptions[menu.selected]);
    try menu.open(alloc, &.{ "dark", "light" }, "dark");
    try std.testing.expectEqual(Purpose.theme, menu.purpose);
    try std.testing.expectEqual(@as(usize, 0), menu.descriptions.len);
}

test "core.theme_menu toggle rows show each state, mark no row as current and report the highlighted state" {
    const alloc = std.testing.allocator;
    var menu: State = .{};
    defer menu.close(alloc);
    try menu.openToggles(alloc, .experiment, "Experimental features", &.{ "wait_for", "tower" }, &.{ true, false });
    try std.testing.expectEqual(Purpose.experiment, menu.purpose);
    try std.testing.expectEqualStrings("Experimental features", menu.title);
    try std.testing.expect(menu.currentName() == null);
    try std.testing.expectEqualStrings("wait_for", menu.selectedName().?);
    try std.testing.expectEqualStrings("enabled", menu.descriptions[0]);
    try std.testing.expectEqualStrings("disabled", menu.descriptions[1]);
    try std.testing.expectEqual(@as(?bool, true), menu.selectedToggleEnabled());
    menu.move(1);
    try std.testing.expectEqualStrings("tower", menu.selectedName().?);
    try std.testing.expectEqual(@as(?bool, false), menu.selectedToggleEnabled());
    try menu.open(alloc, &.{ "dark", "light" }, "dark");
    try std.testing.expectEqual(Purpose.theme, menu.purpose);
    try std.testing.expectEqual(@as(?bool, null), menu.selectedToggleEnabled());
}
