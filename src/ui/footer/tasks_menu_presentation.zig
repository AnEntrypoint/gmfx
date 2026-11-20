const std = @import("std");
const list_window = @import("../../core/shared/list_window.zig");
const render_input = @import("render_input.zig");
const tasks_menu = @import("../../core/input/tasks_menu.zig");
const row_text = @import("row_text.zig");
const ui_render = @import("../render.zig");

const Allocator = std.mem.Allocator;

const Projection = render_input.TasksMenuProjection;

const header_rows: u16 = 1;
pub const max_inline_rows: u16 = header_rows + 12;

fn visibleItems(projection_value: Projection, row_budget: u16) u16 {
    if (row_budget <= header_rows) return 0;
    return @intCast(@min(projection_value.entries.len, row_budget - header_rows));
}

pub fn menuRowCount(projection_value: Projection, row_budget: u16) u16 {
    if (row_budget == 0 or projection_value.entries.len == 0) return 0;
    return header_rows + visibleItems(projection_value, row_budget);
}

pub fn windowStart(projection_value: Projection, row_budget: u16) usize {
    return list_window.updateEdgeStart(projection_value.window_start, projection_value.entries.len, projection_value.selected, @max(visibleItems(projection_value, row_budget), 1));
}

pub fn composeTasksMenuRow(
    alloc: Allocator,
    projection_value: Projection,
    row_index: u16,
    width: u16,
    row_budget: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    if (width == 0 or row_index >= menuRowCount(projection_value, row_budget)) return row;
    if (row_index == 0) {
        var title_buf: [32]u8 = undefined;
        const title = std.fmt.bufPrint(&title_buf, "Tasks {d}", .{projection_value.entries.len}) catch "Tasks";
        try row.appendSlice(alloc, ui_render.selected_completion_style);
        try row_text.appendClipped(alloc, &row, title, width);
        try row.appendSlice(alloc, ui_render.reset_style);
        return row;
    }
    const index = windowStart(projection_value, row_budget) + (row_index - header_rows);
    if (index >= projection_value.entries.len) return row;
    const selected = index == projection_value.selected;
    const indent: usize = if (width <= 2) 0 else 2;
    try row.appendNTimes(alloc, ' ', indent);
    try row.appendSlice(alloc, if (selected) ui_render.selected_completion_style else ui_render.dim_style);
    try row_text.appendSingleLineEllipsized(alloc, &row, projection_value.entries[index].label, @as(usize, width) -| indent);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

test "core.tasks_menu_presentation shows a count header and the selected task label" {
    const alloc = std.testing.allocator;
    const entries = [_]tasks_menu.Entry{
        .{ .id = @constCast("t1"), .label = @constCast("t1  running  sleep 1"), .detail = @constCast("d1") },
        .{ .id = @constCast("t2"), .label = @constCast("t2  done  ls"), .detail = @constCast("d2") },
    };
    const projection_value: Projection = .{ .active = true, .entries = &entries, .selected = 1 };
    try std.testing.expectEqual(@as(u16, 3), menuRowCount(projection_value, 8));
    var header = try composeTasksMenuRow(alloc, projection_value, 0, 40, 8);
    defer header.deinit(alloc);
    try std.testing.expect(std.mem.indexOf(u8, header.items, "Tasks 2") != null);
    var row = try composeTasksMenuRow(alloc, projection_value, 2, 40, 8);
    defer row.deinit(alloc);
    try std.testing.expect(std.mem.indexOf(u8, row.items, "t2  done  ls") != null);
}
