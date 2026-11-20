const std = @import("std");

pub const Facts = struct {
    size_bytes: u64,
    line_count: usize,
    line_count_complete: bool = true,
    mtime_ns: i128,
};

pub fn countLines(text: []const u8) usize {
    var total: usize = 0;
    for (text) |byte| total += @intFromBool(byte == '\n');
    if (text.len > 0 and text[text.len - 1] != '\n') total += 1;
    return total;
}

pub fn write(writer: *std.Io.Writer, facts: Facts) std.Io.Writer.Error!void {
    try writer.print("{d} {s}, ", .{ facts.size_bytes, if (facts.size_bytes == 1) "byte" else "bytes" });
    if (!facts.line_count_complete) try writer.writeAll("at least ");
    try writer.print("{d} {s}, modified ", .{ facts.line_count, if (facts.line_count == 1) "line" else "lines" });
    try writeUtcTimestamp(writer, facts.mtime_ns);
}

pub fn writeUtcTimestamp(writer: *std.Io.Writer, timestamp_ns: i128) std.Io.Writer.Error!void {
    const clamped_secs = std.math.clamp(@divFloor(timestamp_ns, std.time.ns_per_s), 0, max_formatted_epoch_seconds);
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(clamped_secs) };
    const day = epoch.getDaySeconds();
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    try writer.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        @backingInt(month_day.month),
        month_day.day_index + 1,
        day.getHoursIntoDay(),
        day.getMinutesIntoHour(),
        day.getSecondsIntoMinute(),
    });
}

const max_formatted_epoch_seconds: i128 = 253_402_300_799;

fn expectFacts(expected: []const u8, facts: Facts) !void {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try write(&out.writer, facts);
    try std.testing.expectEqualStrings(expected, out.written());
}

test "file facts state size, line count and modification time in UTC" {
    try expectFacts("14 bytes, 3 lines, modified 2026-11-11T10:22:33Z", .{
        .size_bytes = 14,
        .line_count = 3,
        .mtime_ns = 1_794_392_553 * std.time.ns_per_s,
    });
    try expectFacts("1 byte, 1 line, modified 1970-01-01T00:00:00Z", .{
        .size_bytes = 1,
        .line_count = 1,
        .mtime_ns = 999,
    });
    try expectFacts("0 bytes, 0 lines, modified 1970-01-01T00:00:00Z", .{
        .size_bytes = 0,
        .line_count = 0,
        .mtime_ns = -5,
    });
}

test "file facts mark a line count taken from a capped snapshot" {
    try expectFacts("20971520 bytes, at least 12 lines, modified 2001-09-09T01:46:40Z", .{
        .size_bytes = 20 * 1024 * 1024,
        .line_count = 12,
        .line_count_complete = false,
        .mtime_ns = 1_000_000_000 * std.time.ns_per_s,
    });
}

test "countLines counts a final line without a newline" {
    try std.testing.expectEqual(@as(usize, 0), countLines(""));
    try std.testing.expectEqual(@as(usize, 1), countLines("a"));
    try std.testing.expectEqual(@as(usize, 1), countLines("a\n"));
    try std.testing.expectEqual(@as(usize, 2), countLines("a\nb"));
    try std.testing.expectEqual(@as(usize, 3), countLines("a\n\nb\n"));
}
