const std = @import("std");

pub const default_percent: u8 = 85;
pub const min_percent: u8 = 10;
pub const max_percent: u8 = 85;
pub const reserved_context_tokens: usize = 50_000;

pub fn reserveTriggerTokens(context_tokens: usize) ?usize {
    if (context_tokens < reserved_context_tokens * 2) return null;
    return context_tokens - reserved_context_tokens;
}

pub fn isValidPercent(value: u64) bool {
    return value >= min_percent and value <= max_percent;
}

pub fn parsePercent(raw: ?[]const u8) ?u8 {
    const trimmed = std.mem.trim(u8, raw orelse return null, " \t\r\n");
    if (trimmed.len == 0) return null;
    const value = std.fmt.parseUnsigned(u8, trimmed, 10) catch return null;
    return if (isValidPercent(value)) value else null;
}

pub fn resolvePercent(configured: ?u8, process_override: ?[]const u8) u8 {
    return parsePercent(process_override) orelse configured orelse default_percent;
}

pub const command_usage = "usage: /autocompact [percent], a whole number from 10 to 85";

pub fn parseCommandPercent(rest: []const u8) ?u8 {
    return parsePercent(std.mem.trim(u8, rest, " \t%"));
}

test "/autocompact reads a percent with or without a percent sign and refuses one outside the range" {
    try std.testing.expectEqual(@as(?u8, 60), parseCommandPercent("60"));
    try std.testing.expectEqual(@as(?u8, 60), parseCommandPercent(" 60% "));
    try std.testing.expectEqual(@as(?u8, null), parseCommandPercent("95"));
    try std.testing.expectEqual(@as(?u8, null), parseCommandPercent("off"));
    try std.testing.expectEqual(@as(?u8, null), parseCommandPercent(""));
}

test "auto compaction percent accepts only the supported range" {
    try std.testing.expect(!isValidPercent(9));
    try std.testing.expect(isValidPercent(10));
    try std.testing.expect(isValidPercent(80));
    try std.testing.expect(isValidPercent(85));
    try std.testing.expect(!isValidPercent(86));
    try std.testing.expectEqual(@as(?u8, 50), parsePercent(" 50\n"));
    try std.testing.expectEqual(@as(?u8, null), parsePercent("5"));
    try std.testing.expectEqual(@as(?u8, null), parsePercent("90"));
    try std.testing.expectEqual(@as(?u8, null), parsePercent("half"));
    try std.testing.expectEqual(@as(?u8, null), parsePercent(""));
}

test "a window of at least twice the reserve compacts once fewer than 50k tokens of it are left" {
    try std.testing.expectEqual(@as(?usize, 150_000), reserveTriggerTokens(200_000));
    try std.testing.expectEqual(@as(?usize, 50_000), reserveTriggerTokens(100_000));
    try std.testing.expectEqual(@as(?usize, null), reserveTriggerTokens(99_999));
    try std.testing.expectEqual(@as(?usize, null), reserveTriggerTokens(32_000));
}

test "auto compaction percent resolves override, then setting, then default" {
    try std.testing.expectEqual(@as(u8, 85), default_percent);
    try std.testing.expectEqual(default_percent, resolvePercent(null, null));
    try std.testing.expectEqual(@as(u8, 40), resolvePercent(40, null));
    try std.testing.expectEqual(@as(u8, 25), resolvePercent(40, "25"));
    try std.testing.expectEqual(@as(u8, 40), resolvePercent(40, "95"));
}
