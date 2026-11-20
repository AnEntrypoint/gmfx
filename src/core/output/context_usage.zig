const std = @import("std");

const Allocator = std.mem.Allocator;

pub const grid_columns: usize = 20;
pub const grid_rows: usize = 5;
pub const grid_cells: usize = grid_columns * grid_rows;
pub const used_cell = "■";
pub const free_cell = "□";

pub const roomy_suggestion = "Plenty of room. No action needed.";
pub const filling_suggestion = "More than half full. Run /compact before a large task, or /new when the next task is unrelated.";
pub const nearly_full_suggestion = "Nearly full. Run /compact now, or /new for a fresh session. Large tool results, pasted files and long command output fill the window fastest.";
pub const unknown_window_suggestion = "This model does not report a context window, so fx cannot show how full it is.";
pub const no_usage_notice = "Context: no tokens used yet in this session.";

pub fn usedPercent(used_tokens: u64, window_tokens: u32) u64 {
    if (window_tokens == 0) return 0;
    return @min(@as(u64, 100), (used_tokens *| 100) / @as(u64, window_tokens));
}

pub fn usedCells(used_tokens: u64, window_tokens: u32) usize {
    if (window_tokens == 0 or used_tokens == 0) return 0;
    const scaled = (used_tokens *| grid_cells + @as(u64, window_tokens) - 1) / @as(u64, window_tokens);
    return @intCast(@min(@as(u64, grid_cells), scaled));
}

pub fn suggestion(percent: u64) []const u8 {
    if (percent >= 80) return nearly_full_suggestion;
    if (percent >= 50) return filling_suggestion;
    return roomy_suggestion;
}

pub fn render(alloc: Allocator, used_tokens: u64, window: ?u32) Allocator.Error![]u8 {
    if (used_tokens == 0) return alloc.dupe(u8, no_usage_notice);
    const window_tokens = window orelse 0;
    if (window_tokens == 0) {
        return std.fmt.allocPrint(alloc, "Context: {d} tokens used.\n{s}", .{ used_tokens, unknown_window_suggestion });
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    write(&out.writer, used_tokens, window_tokens) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn write(writer: *std.Io.Writer, used_tokens: u64, window_tokens: u32) std.Io.Writer.Error!void {
    const percent = usedPercent(used_tokens, window_tokens);
    const free_tokens = @as(u64, window_tokens) -| used_tokens;
    try writer.print("Context: {d} / {d} tokens ({d}%), {d} free\n", .{ used_tokens, window_tokens, percent, free_tokens });
    const filled = usedCells(used_tokens, window_tokens);
    for (0..grid_rows) |row| {
        for (0..grid_columns) |column| {
            try writer.writeAll(if (row * grid_columns + column < filled) used_cell else free_cell);
        }
        try writer.writeByte('\n');
    }
    try writer.writeAll(suggestion(percent));
}

test "the context grid fills one cell per percent and never shows a used session as empty" {
    try std.testing.expectEqual(@as(usize, 100), grid_cells);
    try std.testing.expectEqual(@as(usize, 0), usedCells(0, 200_000));
    try std.testing.expectEqual(@as(usize, 1), usedCells(1, 200_000));
    try std.testing.expectEqual(@as(usize, 22), usedCells(43_000, 200_000));
    try std.testing.expectEqual(@as(usize, 100), usedCells(250_000, 200_000));
    try std.testing.expectEqual(@as(u64, 21), usedPercent(43_000, 200_000));
    try std.testing.expectEqual(@as(u64, 100), usedPercent(250_000, 200_000));
    try std.testing.expectEqual(@as(u64, 0), usedPercent(5, 0));
}

test "the suggestion follows how full the window is" {
    try std.testing.expectEqualStrings(roomy_suggestion, suggestion(49));
    try std.testing.expectEqualStrings(filling_suggestion, suggestion(50));
    try std.testing.expectEqualStrings(filling_suggestion, suggestion(79));
    try std.testing.expectEqualStrings(nearly_full_suggestion, suggestion(80));
}

test "/context text shows the totals, a grid of used and free cells, and a suggestion" {
    const alloc = std.testing.allocator;
    const text = try render(alloc, 100_000, 200_000);
    defer alloc.free(text);

    var lines = std.mem.splitScalar(u8, text, '\n');
    try std.testing.expectEqualStrings("Context: 100000 / 200000 tokens (50%), 100000 free", lines.next().?);
    var used: usize = 0;
    var free: usize = 0;
    for (0..grid_rows) |_| {
        const line = lines.next().?;
        used += std.mem.count(u8, line, used_cell);
        free += std.mem.count(u8, line, free_cell);
    }
    try std.testing.expectEqual(@as(usize, 50), used);
    try std.testing.expectEqual(@as(usize, 50), free);
    try std.testing.expectEqualStrings(filling_suggestion, lines.next().?);
    try std.testing.expect(lines.next() == null);
}

test "/context text says so when nothing was used or the window is unknown" {
    const alloc = std.testing.allocator;
    const unused = try render(alloc, 0, 200_000);
    defer alloc.free(unused);
    try std.testing.expectEqualStrings(no_usage_notice, unused);

    const windowless = try render(alloc, 1_234, null);
    defer alloc.free(windowless);
    try std.testing.expectEqualStrings("Context: 1234 tokens used.\n" ++ unknown_window_suggestion, windowless);
}
