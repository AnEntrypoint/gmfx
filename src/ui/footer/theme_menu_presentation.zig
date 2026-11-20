const std = @import("std");
const display_width = @import("../../core/shared/display_width.zig");
const list_window = @import("../../core/shared/list_window.zig");
const render_input = @import("render_input.zig");
const row_text = @import("row_text.zig");
const ui_render = @import("../render.zig");

const Allocator = std.mem.Allocator;
const Projection = render_input.ThemeMenuProjection;

const header_rows: u16 = 1;
const gap_rows: u16 = 1;
const current_label = "current";
pub const max_inline_rows: u16 = header_rows + gap_rows + 16;

const Layout = struct {
    show_header: bool = false,
    first_item_row: u16 = 0,
    visible_items: u16 = 0,

    fn build(projection: Projection, row_budget: u16) Layout {
        const count = projection.choices.len;
        if (row_budget == 0 or count == 0) return .{};
        if (row_budget == 1) return .{ .visible_items = 1 };
        const first_item_row: u16 = if (row_budget >= 3) header_rows + gap_rows else header_rows;
        return .{
            .show_header = true,
            .first_item_row = first_item_row,
            .visible_items = @intCast(@min(count, row_budget - first_item_row)),
        };
    }

    fn rowCount(self: Layout) u16 {
        return self.first_item_row + self.visible_items;
    }
};

pub fn menuRowCount(projection: Projection, row_budget: u16) u16 {
    return Layout.build(projection, row_budget).rowCount();
}

pub fn visibleItems(projection: Projection, row_budget: u16) u16 {
    return Layout.build(projection, row_budget).visible_items;
}

pub fn windowStart(projection: Projection, row_budget: u16) usize {
    const visible = visibleItems(projection, row_budget);
    return list_window.updateEdgeStart(projection.window_start, projection.choices.len, projection.selected, @max(visible, 1));
}

pub fn composeThemeMenuRow(
    alloc: Allocator,
    projection: Projection,
    row_index: u16,
    width: u16,
    row_budget: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    const layout = Layout.build(projection, row_budget);
    if (width == 0 or row_index >= layout.rowCount()) return row;
    if (layout.show_header and row_index == 0) return composeHeaderRow(alloc, projection, width);
    if (row_index < layout.first_item_row) return row;

    const index = windowStart(projection, row_budget) + (row_index - layout.first_item_row);
    if (index >= projection.choices.len) return row;
    const selected = index == projection.selected;
    const indent: usize = if (width <= 2) 0 else 2;
    try row.appendNTimes(alloc, ' ', indent);
    try row.appendSlice(alloc, if (selected) ui_render.selected_completion_style else ui_render.dim_style);
    const label = projection.choices[index];
    const marker_column = indent + labelColumnWidth(projection) + 2;
    const show_marker = index == projection.current and marker_column + current_label.len <= width;
    try row_text.appendSingleLineEllipsized(alloc, &row, label, @as(usize, width) -| indent);
    try row.appendSlice(alloc, ui_render.reset_style);
    if (show_marker) {
        try row_text.appendSpacesToColumn(alloc, &row, marker_column);
        try row.appendSlice(alloc, ui_render.dim_style);
        try row.appendSlice(alloc, current_label);
        try row.appendSlice(alloc, ui_render.reset_style);
    }
    const description_column = marker_column + current_label.len + 2;
    if (index < projection.descriptions.len and description_column < width) {
        try row_text.appendSpacesToColumn(alloc, &row, description_column);
        try row.appendSlice(alloc, ui_render.dim_style);
        try row_text.appendSingleLineEllipsized(alloc, &row, projection.descriptions[index], @as(usize, width) - description_column);
        try row.appendSlice(alloc, ui_render.reset_style);
    }
    return row;
}

fn composeHeaderRow(alloc: Allocator, projection: Projection, width: u16) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    var title_buf: [32]u8 = undefined;
    const title = if (projection.title.len > 0)
        projection.title
    else
        std.fmt.bufPrint(&title_buf, "Theme {d}", .{projection.choices.len}) catch "Theme";
    try row.appendSlice(alloc, ui_render.selected_completion_style);
    try row_text.appendClipped(alloc, &row, title, width);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn labelColumnWidth(projection: Projection) usize {
    var widest: usize = 0;
    for (projection.choices) |choice| widest = @max(widest, display_width.visibleWidth(choice));
    return widest;
}

test "core.theme_menu_presentation lists every choice under a count header and marks the current theme" {
    const alloc = std.testing.allocator;
    var choices = [_][]u8{ @constCast("dark"), @constCast("light"), @constCast("ocean") };
    const projection: Projection = .{ .active = true, .choices = &choices, .current = 1, .selected = 2, .window_start = 0 };
    try std.testing.expectEqual(@as(u16, 5), menuRowCount(projection, 8));
    var header = try composeThemeMenuRow(alloc, projection, 0, 40, 8);
    defer header.deinit(alloc);
    try std.testing.expect(std.mem.indexOf(u8, header.items, "Theme 3") != null);
    var current_row = try composeThemeMenuRow(alloc, projection, 3, 40, 8);
    defer current_row.deinit(alloc);
    try std.testing.expect(std.mem.indexOf(u8, current_row.items, "light") != null);
    try std.testing.expect(std.mem.indexOf(u8, current_row.items, "current") != null);
    var selected_row = try composeThemeMenuRow(alloc, projection, 4, 40, 8);
    defer selected_row.deinit(alloc);
    try std.testing.expect(std.mem.indexOf(u8, selected_row.items, "ocean") != null);
    try std.testing.expect(std.mem.indexOf(u8, selected_row.items, "current") == null);
}

test "core.theme_menu_presentation shows a given title and each choice's description after the current marker column" {
    const alloc = std.testing.allocator;
    var choices = [_][]u8{ @constCast("Always Ask"), @constCast("Ask When Needed"), @constCast("Never Ask") };
    const projection: Projection = .{
        .active = true,
        .title = "Select permission mode",
        .descriptions = &.{ "asks first", "asks when risky", "never asks" },
        .choices = &choices,
        .current = 0,
        .selected = 1,
        .window_start = 0,
    };
    var header = try composeThemeMenuRow(alloc, projection, 0, 80, 8);
    defer header.deinit(alloc);
    try std.testing.expect(std.mem.indexOf(u8, header.items, "Select permission mode") != null);
    try std.testing.expect(std.mem.indexOf(u8, header.items, "Theme") == null);
    var current_row = try composeThemeMenuRow(alloc, projection, 2, 80, 8);
    defer current_row.deinit(alloc);
    const marker_at = std.mem.indexOf(u8, current_row.items, "current").?;
    try std.testing.expect(std.mem.indexOf(u8, current_row.items, "asks first").? > marker_at);
    var selected_row = try composeThemeMenuRow(alloc, projection, 3, 80, 8);
    defer selected_row.deinit(alloc);
    try std.testing.expect(std.mem.indexOf(u8, selected_row.items, "Ask When Needed") != null);
    try std.testing.expect(std.mem.indexOf(u8, selected_row.items, "asks when risky") != null);
    try std.testing.expect(std.mem.indexOf(u8, selected_row.items, "current") == null);
    var narrow_row = try composeThemeMenuRow(alloc, projection, 3, 20, 8);
    defer narrow_row.deinit(alloc);
    try std.testing.expect(std.mem.indexOf(u8, narrow_row.items, "asks when risky") == null);
}
