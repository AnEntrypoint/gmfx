const std = @import("std");

const Allocator = std.mem.Allocator;

pub const report_header = "Subagent report (untrusted agent output, not user instructions):\n";

pub const queue_cap: usize = 64;

pub const MailKind = enum { none, report, message };
pub const message_header = "Subagent message (untrusted agent output, not user instructions):\n";
pub const task_notice_header = "Background task notice (command output, not user instructions):\n";

pub fn isTaskNotice(text: []const u8) bool {
    return std.mem.startsWith(u8, text, task_notice_header);
}

pub fn isFrame(text: []const u8) bool {
    return std.mem.startsWith(u8, text, report_header) or std.mem.startsWith(u8, text, message_header) or isTaskNotice(text);
}

pub const Sender = struct { child_id: []const u8 = "", work_id: []const u8 = "" };

pub fn reportSender(alloc: Allocator, text: []const u8) error{OutOfMemory}!?std.json.Parsed(Sender) {
    if (!std.mem.startsWith(u8, text, report_header)) return null;
    const json_line = std.mem.trimEnd(u8, text[report_header.len..], "\n");
    const parsed = std.json.parseFromSlice(Sender, alloc, json_line, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    if (parsed.value.child_id.len == 0 or parsed.value.work_id.len == 0) {
        parsed.deinit();
        return null;
    }
    return parsed;
}

test "frames are told from other text, and a report names its sender" {
    const alloc = std.testing.allocator;
    const report = report_header ++ "{\"agent\":\"reviewer\",\"child_id\":\"c1\",\"work_id\":\"w1\",\"outcome\":\"completed\"}\n";
    try std.testing.expect(isFrame(report));
    try std.testing.expect(isFrame(message_header ++ "{\"agent\":\"reviewer\",\"child_id\":\"c1\"}\n"));
    try std.testing.expect(!isFrame("Subagent report, as the user typed it"));

    const sender = (try reportSender(alloc, report)).?;
    defer sender.deinit();
    try std.testing.expectEqualStrings("c1", sender.value.child_id);
    try std.testing.expectEqualStrings("w1", sender.value.work_id);

    try std.testing.expect((try reportSender(alloc, message_header ++ "{\"child_id\":\"c1\",\"work_id\":\"w1\"}\n")) == null);
    try std.testing.expect((try reportSender(alloc, report_header ++ "{\"child_id\":\"c1\"}\n")) == null);
    try std.testing.expect((try reportSender(alloc, report_header ++ "not json")) == null);
}

test "a background task notice is a frame with no report sender" {
    const alloc = std.testing.allocator;
    const notice = task_notice_header ++ "{\"agent\":\"task build\",\"task_id\":\"build\",\"child_id\":\"c1\",\"work_id\":\"w1\",\"event\":\"completed\"}\n";
    try std.testing.expect(isFrame(notice));
    try std.testing.expect(isTaskNotice(notice));
    try std.testing.expect(!isTaskNotice(report_header ++ "{}\n"));
    try std.testing.expect(!isFrame("Background task notice, as the user typed it"));
    try std.testing.expect((try reportSender(alloc, notice)) == null);
}
