const std = @import("std");
const display_width = @import("../../core/shared/display_width.zig");
const info_panel = @import("../../core/input/info_panel.zig");
const picker_presentation = @import("picker_presentation.zig");
const render_input = @import("render_input.zig");
const row_text = @import("row_text.zig");
const ui_render = @import("../render.zig");

const Allocator = std.mem.Allocator;
const Projection = render_input.InfoPanelProjection;
const Row = info_panel.Row;

const indent: usize = 2;
const column_gap: usize = 4;
const min_value_width: usize = 24;
const header_rows: u16 = 2;
const bullet = "• ";
const bullet_width: usize = 2;

pub fn desiredRowCount(projection: Projection, width: u16) u16 {
    return std.math.cast(u16, header_rows + lineCount(projection.rows, width)) orelse std.math.maxInt(u16);
}

pub fn footerRows(projection: Projection, width: u16, terminal_rows: u16) u16 {
    return picker_presentation.inlinePickerRowBudgetCapped(terminal_rows, 0, 0, desiredRowCount(projection, width));
}

pub fn visibleLineCount(visible_rows: u16) usize {
    return visible_rows -| headerRowsFor(visible_rows);
}

pub fn overflows(projection: Projection, width: u16, terminal_rows: u16) bool {
    return lineCount(projection.rows, width) > visibleLineCount(footerRows(projection, width, terminal_rows));
}

pub fn lineCount(rows: []const Row, width: u16) usize {
    const value_width = valueWidth(rows, width);
    var count: usize = 0;
    for (rows) |row| count += wrappedLineCount(row.value, textWidth(row, value_width));
    return count;
}

pub fn composeRow(
    alloc: Allocator,
    projection: Projection,
    row_index: u16,
    visible_rows: u16,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    if (width == 0 or row_index >= visible_rows) return row;
    const header = headerRowsFor(visible_rows);
    if (row_index < header) {
        if (row_index == 0) {
            try row.appendSlice(alloc, ui_render.selected_completion_style);
            try row_text.appendSingleLineEllipsized(alloc, &row, projection.title, width);
            try row.appendSlice(alloc, ui_render.reset_style);
        }
        return row;
    }

    const total = lineCount(projection.rows, width);
    const visible = visibleLineCount(visible_rows);
    const start = @min(projection.scroll, total -| visible);
    const wanted = start + (row_index - header);
    const value_col = valueColumn(projection.rows, width);
    const value_width = valueWidth(projection.rows, width);

    var line: usize = 0;
    for (projection.rows) |panel_row| {
        const text_width = textWidth(panel_row, value_width);
        var rest = panel_row.value;
        var first = true;
        while (first or rest.len > 0) : (first = false) {
            const cut = nextBreak(rest, text_width);
            if (line == wanted) {
                const lead = if (!panel_row.item) "" else if (first) bullet else "  ";
                try composeLine(alloc, &row, if (first) panel_row.label else "", lead, rest[0..cut.end], value_col, width);
                return row;
            }
            rest = rest[cut.next..];
            line += 1;
        }
    }
    return row;
}

fn composeLine(
    alloc: Allocator,
    row: *std.ArrayList(u8),
    label: []const u8,
    lead: []const u8,
    value: []const u8,
    value_col: usize,
    width: u16,
) !void {
    const total_width: usize = width;
    try row.appendSlice(alloc, ui_render.system_notice_label_style);
    try row_text.appendClipped(alloc, row, "  ", width);
    try row_text.appendSingleLineEllipsized(alloc, row, label, value_col -| indent -| 1);
    try row.appendSlice(alloc, ui_render.reset_style);
    const used = display_width.visibleWidthIgnoringAnsi(row.items);
    if (used >= total_width or value_col >= total_width) return;
    try row.appendNTimes(alloc, ' ', value_col -| used);
    try row.appendSlice(alloc, ui_render.dim_style);
    const room = total_width - value_col;
    try row_text.appendSingleLineEllipsized(alloc, row, lead, room);
    try row_text.appendSingleLineEllipsized(alloc, row, value, room -| display_width.visibleWidth(lead));
    try row.appendSlice(alloc, ui_render.reset_style);
}

fn headerRowsFor(visible_rows: u16) u16 {
    if (visible_rows > header_rows + 1) return header_rows;
    return @intFromBool(visible_rows > 1);
}

fn valueColumn(rows: []const Row, width: u16) usize {
    var longest: usize = 0;
    for (rows) |row| longest = @max(longest, display_width.visibleWidth(row.label));
    const total_width: usize = width;
    const roomy = indent + longest + column_gap;
    if (roomy + min_value_width <= total_width) return roomy;
    return @min(indent + longest + 2, total_width);
}

fn valueWidth(rows: []const Row, width: u16) usize {
    return @max(@as(usize, width) -| valueColumn(rows, width), 1);
}

fn textWidth(row: Row, value_width: usize) usize {
    return if (row.item) @max(value_width -| bullet_width, 1) else value_width;
}

fn wrappedLineCount(value: []const u8, text_width: usize) usize {
    var rest = value;
    var count: usize = 0;
    while (true) {
        count += 1;
        const cut = nextBreak(rest, text_width);
        rest = rest[cut.next..];
        if (rest.len == 0) return count;
    }
}

const Break = struct {
    end: usize,
    next: usize,
};

fn nextBreak(text: []const u8, width: usize) Break {
    if (display_width.visibleWidth(text) <= width) return .{ .end = text.len, .next = text.len };
    var col: usize = 0;
    var index: usize = 0;
    var last_space: ?usize = null;
    var last_slash: ?usize = null;
    while (index < text.len) {
        const len = display_width.decodeNextRune(text, index).len;
        const rune_width = display_width.visibleWidth(text[index .. index + len]);
        if (col + rune_width > width) break;
        if (text[index] == ' ') last_space = index;
        if (text[index] == '/') last_slash = index + 1;
        col += rune_width;
        index += len;
    }
    if (index == 0) {
        const len = display_width.decodeNextRune(text, 0).len;
        return .{ .end = len, .next = len };
    }
    if (last_space) |space| if (space > 0) return .{ .end = space, .next = space + 1 };
    if (last_slash) |slash| return .{ .end = slash, .next = slash };
    return .{ .end = index, .next = if (text[index] == ' ') index + 1 else index };
}
