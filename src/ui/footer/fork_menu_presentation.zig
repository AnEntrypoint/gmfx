const std = @import("std");
const input_presentation = @import("input_presentation.zig");
const render_input = @import("render_input.zig");
const row_text = @import("row_text.zig");
const ui_render = @import("../render.zig");

const Allocator = std.mem.Allocator;
const ForkMenuProjection = render_input.ForkMenuProjection;

const max_prompt_lines = render_input.max_message_layout_rows;
pub const max_inline_rows: u16 = 6 * max_prompt_lines;

fn indentWidth(width: u16) u16 {
    return if (width > 4) 2 else 0;
}

fn promptLayout(prompt: []const u8, width: u16) render_input.SteeringMessageLayout {
    return render_input.steering_message_layout(prompt, width - indentWidth(width), false, max_prompt_lines);
}

const Lines = struct {
    total: usize = 0,
    selected_start: usize = 0,
    selected_end: usize = 0,

    fn measure(projection: ForkMenuProjection, width: u16) Lines {
        var lines: Lines = .{};
        for (projection.points, 0..) |point, index| {
            if (index == projection.selected) lines.selected_start = lines.total;
            lines.total += promptLayout(point.prompt, width).row_count;
            if (index == projection.selected) lines.selected_end = lines.total;
        }
        return lines;
    }
};

const undo_title = "Select messages to undo";

fn titleRows(projection: ForkMenuProjection, row_budget: u16) u16 {
    return if (projection.undo and row_budget > 1) 1 else 0;
}

fn promptBudget(projection: ForkMenuProjection, row_budget: u16) u16 {
    return row_budget - titleRows(projection, row_budget);
}

pub fn menuRowCount(projection: ForkMenuProjection, width: u16, row_budget: u16) u16 {
    const title = titleRows(projection, row_budget);
    const prompts: u16 = @intCast(@min(row_budget - title, Lines.measure(projection, width).total));
    return title + prompts;
}

pub fn windowStart(projection: ForkMenuProjection, width: u16, row_budget: u16) usize {
    const lines = Lines.measure(projection, width);
    const height: usize = @min(promptBudget(projection, row_budget), lines.total);
    var start = @min(projection.window_start, lines.total - height);
    if (lines.selected_start < start) start = lines.selected_start;
    if (lines.selected_end > start + height) start = @min(lines.selected_start, lines.selected_end - height);
    return start;
}

pub fn composeForkMenuRow(
    alloc: Allocator,
    projection: ForkMenuProjection,
    row_index: u16,
    width: u16,
    row_budget: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    if (width == 0 or row_index >= row_budget) return row;
    const title = titleRows(projection, row_budget);
    if (row_index < title) return composeUndoTitle(alloc, width);
    const line = windowStart(projection, width, row_budget) + (row_index - title);
    var first: usize = 0;
    for (projection.points, 0..) |point, index| {
        const layout = promptLayout(point.prompt, width);
        if (line < first + layout.row_count) {
            try row.appendNTimes(alloc, ' ', indentWidth(width));
            try row.appendSlice(alloc, if (index == projection.selected) ui_render.selected_completion_style else ui_render.dim_style);
            try input_presentation.appendMessageLayoutRow(alloc, &row, layout, line - first);
            try row.appendSlice(alloc, ui_render.reset_style);
            return row;
        }
        first += layout.row_count;
    }
    return row;
}

fn composeUndoTitle(alloc: Allocator, width: u16) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row.appendSlice(alloc, ui_render.selected_completion_style);
    try row_text.appendClipped(alloc, &row, undo_title, width);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

const ForkPoint = std.meta.Child(@FieldType(ForkMenuProjection, "points"));

fn testRow(projection: ForkMenuProjection, row_index: u16, width: u16, row_budget: u16) !struct { text: []u8, selected: bool } {
    const alloc = std.testing.allocator;
    var row = try composeForkMenuRow(alloc, projection, row_index, width, row_budget);
    defer row.deinit(alloc);
    const selected = std.mem.find(u8, row.items, ui_render.selected_completion_style) != null;
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(alloc);
    var index: usize = 0;
    while (index < row.items.len) {
        if (row.items[index] == 0x1b) {
            index = std.mem.findScalarPos(u8, row.items, index, 'm').? + 1;
            continue;
        }
        try text.append(alloc, row.items[index]);
        index += 1;
    }
    return .{ .text = try text.toOwnedSlice(alloc), .selected = selected };
}

test "fork menu shows each prompt in at most three lines, ending a cut one with an ellipsis" {
    const points = [_]ForkPoint{
        .{ .turn = 1, .prompt = @constCast("one two three four five six seven eight nine ten eleven twelve") },
        .{ .turn = 2, .prompt = @constCast("short\nsecond line") },
    };
    const projection: ForkMenuProjection = .{ .points = &points, .selected = 1, .window_start = 0 };
    try std.testing.expectEqual(@as(u16, 5), menuRowCount(projection, 16, max_inline_rows));
    const expected = [_][]const u8{ "  one two three", "  four five six", "  seven eight…", "  short", "  second line" };
    for (expected, 0..) |text, row_index| {
        const row = try testRow(projection, @intCast(row_index), 16, max_inline_rows);
        defer std.testing.allocator.free(row.text);
        try std.testing.expectEqualStrings(text, row.text);
        try std.testing.expectEqual(row_index >= 3, row.selected);
    }
}

test "undo menu titles the list and keeps the newest prompt at the bottom" {
    const points = [_]ForkPoint{
        .{ .turn = 1, .prompt = @constCast("first") },
        .{ .turn = 2, .prompt = @constCast("second") },
        .{ .turn = 3, .prompt = @constCast("third") },
    };
    const projection: ForkMenuProjection = .{ .points = &points, .selected = 2, .window_start = 0, .undo = true };
    try std.testing.expectEqual(@as(u16, 4), menuRowCount(projection, 40, 4));

    const title = try testRow(projection, 0, 40, 4);
    defer std.testing.allocator.free(title.text);
    try std.testing.expectEqualStrings("Select messages to undo", title.text);

    const bottom = try testRow(projection, 3, 40, 4);
    defer std.testing.allocator.free(bottom.text);
    try std.testing.expectEqualStrings("  third", bottom.text);
    try std.testing.expect(bottom.selected);
}

test "fork menu lists prompts oldest first and opens on the newest at the bottom" {
    const points = [_]ForkPoint{
        .{ .turn = 1, .prompt = @constCast("first") },
        .{ .turn = 2, .prompt = @constCast("second") },
        .{ .turn = 3, .prompt = @constCast("third") },
    };

    var projection: ForkMenuProjection = .{ .points = &points, .selected = 2, .window_start = std.math.maxInt(usize) };
    for ([_][]const u8{ "  first", "  second", "  third" }, 0..) |text, row_index| {
        const row = try testRow(projection, @intCast(row_index), 40, 3);
        defer std.testing.allocator.free(row.text);
        try std.testing.expectEqualStrings(text, row.text);
        try std.testing.expectEqual(row_index == 2, row.selected);
    }

    const steps = [_]struct { selected: usize, top: []const u8, bottom: []const u8 }{
        .{ .selected = 2, .top = "  second", .bottom = "  third" },
        .{ .selected = 1, .top = "  second", .bottom = "  third" },
        .{ .selected = 0, .top = "  first", .bottom = "  second" },
        .{ .selected = 1, .top = "  first", .bottom = "  second" },
    };
    for (steps) |step| {
        projection.selected = step.selected;
        projection.window_start = windowStart(projection, 40, 2);
        const top = try testRow(projection, 0, 40, 2);
        defer std.testing.allocator.free(top.text);
        const bottom = try testRow(projection, 1, 40, 2);
        defer std.testing.allocator.free(bottom.text);
        try std.testing.expectEqualStrings(step.top, top.text);
        try std.testing.expectEqualStrings(step.bottom, bottom.text);
    }
}
