const std = @import("std");
const local_time = @import("../shared/local_time.zig");

const Allocator = std.mem.Allocator;

pub const tower_root = ".tower";
pub const comms_dir = tower_root ++ "/comms";
pub const inbox_dir = comms_dir ++ "/inbox";
pub const findings_dir = comms_dir ++ "/findings";
pub const reviews_dir = comms_dir ++ "/reviews";
pub const missions_dir = comms_dir ++ "/missions";
pub const log_dir = comms_dir ++ "/log";
pub const worktrees_dir = tower_root ++ "/worktrees";
pub const state_file = comms_dir ++ "/state.json";
pub const activity_log = log_dir ++ "/activity.log";
pub const missions_index = comms_dir ++ "/MISSIONS.md";

pub const tower_name = "tower";
pub const broadcast_name = "all";

pub fn isReservedAgentName(name: []const u8) bool {
    return std.mem.eql(u8, name, tower_name) or std.mem.eql(u8, name, broadcast_name);
}

pub fn dateStamp(alloc: Allocator, timestamp_ms: i64) ![]u8 {
    const reading = local_time.local(timestamp_ms) orelse return error.InvalidTimestamp;
    return std.fmt.allocPrint(alloc, "{d:0>4}{d:0>2}{d:0>2}", .{
        reading.year,
        reading.month.numeric(),
        reading.day,
    });
}

pub fn dateDash(alloc: Allocator, timestamp_ms: i64) ![]u8 {
    const reading = local_time.local(timestamp_ms) orelse return error.InvalidTimestamp;
    return std.fmt.allocPrint(alloc, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        reading.year,
        reading.month.numeric(),
        reading.day,
    });
}

pub fn isoTimestamp(alloc: Allocator, timestamp_ms: i64) ![]u8 {
    if (timestamp_ms < 0) return error.InvalidTimestamp;
    const seconds: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@divFloor(timestamp_ms, std.time.ms_per_s)) };
    const year_day = seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = seconds.getDaySeconds();
    return std.fmt.allocPrint(alloc, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        year_day.year,
        month_day.month.numeric(),
        @as(u32, month_day.day_index) + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
        @as(u32, @intCast(@mod(timestamp_ms, std.time.ms_per_s))),
    });
}

pub fn slugify(alloc: Allocator, text: []const u8, max_length: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var pending_dash = false;
    for (text) |byte| {
        const lower = std.ascii.toLower(byte);
        if (std.ascii.isAlphanumeric(lower)) {
            if (pending_dash and out.items.len > 0) try out.append(alloc, '-');
            try out.append(alloc, lower);
            pending_dash = false;
        } else {
            pending_dash = true;
        }
    }
    if (out.items.len > max_length) out.shrinkRetainingCapacity(max_length);
    while (out.items.len > 0 and out.items[out.items.len - 1] == '-') _ = out.pop();
    if (out.items.len == 0) try out.appendSlice(alloc, "item");
    return out.toOwnedSlice(alloc);
}

pub fn hasNonAsciiCharacters(text: []const u8) bool {
    for (text) |byte| {
        if (byte < 0x20 or byte > 0x7e) return true;
    }
    return false;
}

pub fn targetSlug(alloc: Allocator, target: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, target, " \t\r\n");
    const cleaned = if (std.mem.startsWith(u8, trimmed, "#"))
        try std.fmt.allocPrint(alloc, "pr{s}", .{trimmed[1..]})
    else
        try alloc.dupe(u8, trimmed);
    defer alloc.free(cleaned);
    return slugify(alloc, cleaned, 60);
}

pub fn inboxFileName(alloc: Allocator, stamp: []const u8, from: []const u8, to: []const u8, subject: []const u8) ![]u8 {
    const from_slug = try slugify(alloc, from, 30);
    defer alloc.free(from_slug);
    const to_slug = try slugify(alloc, to, 30);
    defer alloc.free(to_slug);
    const subject_slug = try slugify(alloc, subject, 60);
    defer alloc.free(subject_slug);
    return std.fmt.allocPrint(alloc, "{s}-{s}-{s}-{s}.md", .{ stamp, from_slug, to_slug, subject_slug });
}

pub fn findingFileName(alloc: Allocator, stamp: []const u8, agent: []const u8, finding_type: []const u8, slug_text: []const u8) ![]u8 {
    const agent_slug = try slugify(alloc, agent, 30);
    defer alloc.free(agent_slug);
    const type_slug = try slugify(alloc, finding_type, 12);
    defer alloc.free(type_slug);
    const body_slug = try slugify(alloc, slug_text, 60);
    defer alloc.free(body_slug);
    return std.fmt.allocPrint(alloc, "{s}-{s}-{s}-{s}.md", .{ stamp, agent_slug, type_slug, body_slug });
}

pub fn reviewFileName(alloc: Allocator, target: []const u8, reviewer: []const u8, round: u32) ![]u8 {
    const target_part = try targetSlug(alloc, target);
    defer alloc.free(target_part);
    const reviewer_slug = try slugify(alloc, reviewer, 30);
    defer alloc.free(reviewer_slug);
    return std.fmt.allocPrint(alloc, "review-{s}-{s}-r{d}.md", .{ target_part, reviewer_slug, round });
}

pub fn missionFileName(alloc: Allocator, id: []const u8, slug_text: []const u8) ![]u8 {
    const body_slug = try slugify(alloc, slug_text, 60);
    defer alloc.free(body_slug);
    return std.fmt.allocPrint(alloc, "{s}-{s}.md", .{ id, body_slug });
}

test "Tower paths slugify lowercases ASCII words and falls back to item" {
    const alloc = std.testing.allocator;
    const plain = try slugify(alloc, "  Fix the: Parser!! ", 60);
    defer alloc.free(plain);
    try std.testing.expectEqualStrings("fix-the-parser", plain);
    const empty = try slugify(alloc, "***", 60);
    defer alloc.free(empty);
    try std.testing.expectEqualStrings("item", empty);
}

test "Tower paths slugify truncates and drops a trailing dash" {
    const alloc = std.testing.allocator;
    const cut = try slugify(alloc, "ab cd", 3);
    defer alloc.free(cut);
    try std.testing.expectEqualStrings("ab", cut);
}

test "Tower paths targetSlug maps a leading hash to pr and slashes to dashes" {
    const alloc = std.testing.allocator;
    const pr = try targetSlug(alloc, "#42");
    defer alloc.free(pr);
    try std.testing.expectEqualStrings("pr42", pr);
    const branch = try targetSlug(alloc, "feature/x#y");
    defer alloc.free(branch);
    try std.testing.expectEqualStrings("feature-x-y", branch);
}

test "Tower paths file names combine the stamp and slugs" {
    const alloc = std.testing.allocator;
    const inbox = try inboxFileName(alloc, "20260501", "Worker A", "tower", "Done: merge");
    defer alloc.free(inbox);
    try std.testing.expectEqualStrings("20260501-worker-a-tower-done-merge.md", inbox);
    const finding = try findingFileName(alloc, "20260501", "reviewer", "vulnerability-type-long", "Bad input");
    defer alloc.free(finding);
    try std.testing.expectEqualStrings("20260501-reviewer-vulnerabilit-bad-input.md", finding);
    const review = try reviewFileName(alloc, "#7", "rev", 2);
    defer alloc.free(review);
    try std.testing.expectEqualStrings("review-pr7-rev-r2.md", review);
    const mission = try missionFileName(alloc, "m1", "Parser: tokens");
    defer alloc.free(mission);
    try std.testing.expectEqualStrings("m1-parser-tokens.md", mission);
}

test "Tower paths reserve the tower and all agent names" {
    try std.testing.expect(isReservedAgentName("tower"));
    try std.testing.expect(isReservedAgentName("all"));
    try std.testing.expect(!isReservedAgentName("worker"));
}

test "Tower paths detect non-ASCII text" {
    try std.testing.expect(hasNonAsciiCharacters("café"));
    try std.testing.expect(!hasNonAsciiCharacters("plain ASCII"));
}

test "Tower paths format UTC ISO timestamps" {
    const alloc = std.testing.allocator;
    const epoch = try isoTimestamp(alloc, 0);
    defer alloc.free(epoch);
    try std.testing.expectEqualStrings("1970-01-01T00:00:00.000Z", epoch);
    const later = try isoTimestamp(alloc, 1_777_593_600_123);
    defer alloc.free(later);
    try std.testing.expectEqualStrings("2026-05-01T00:00:00.123Z", later);
}
