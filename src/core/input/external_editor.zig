const std = @import("std");

const Allocator = std.mem.Allocator;

pub const max_command_bytes: usize = 512;
pub const max_draft_bytes: usize = 4 * 1024 * 1024;
pub const no_editor_notice = "No external editor is set. Set VISUAL or EDITOR, or run /editor <command>.";
pub const unavailable_notice = "An external editor cannot be opened in this runtime.";
pub const failed_notice = "The external editor did not exit cleanly, so the draft was left as it was.";
pub const empty_draft_notice = "The external editor saved an empty draft.";
pub const command_too_long_notice = "That editor command is too long.";

var session_command_bytes: [max_command_bytes]u8 = undefined;
var session_command_len: usize = 0;

pub fn chooseForSession(command: []const u8) error{EditorCommandTooLong}!void {
    const value = std.mem.trim(u8, command, " \t\r\n");
    if (value.len > max_command_bytes) return error.EditorCommandTooLong;
    @memcpy(session_command_bytes[0..value.len], value);
    session_command_len = value.len;
}

pub fn sessionCommand() ?[]const u8 {
    if (session_command_len == 0) return null;
    return session_command_bytes[0..session_command_len];
}

pub fn resolveCommand(chosen: ?[]const u8, visual: ?[]const u8, editor: ?[]const u8) ?[]const u8 {
    for ([_]?[]const u8{ chosen, visual, editor }) |candidate| {
        const value = std.mem.trim(u8, candidate orelse continue, " \t\r\n");
        if (value.len > 0) return value;
    }
    return null;
}

pub fn argvFor(alloc: Allocator, command: []const u8, draft_path: []const u8) Allocator.Error![]const []const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    errdefer words.deinit(alloc);
    var tokens = std.mem.tokenizeAny(u8, command, " \t");
    while (tokens.next()) |word| try words.append(alloc, word);
    try words.append(alloc, draft_path);
    return words.toOwnedSlice(alloc);
}

pub fn draftPath(alloc: Allocator, tmp_dir: []const u8, now_ms: i64) Allocator.Error![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/fx-draft-{d}.md", .{ std.mem.trimEnd(u8, tmp_dir, "/"), now_ms });
}

pub fn draftText(saved: []const u8) []const u8 {
    return std.mem.trimEnd(u8, saved, "\r\n");
}

test "the editor is the one chosen with /editor, then VISUAL, then EDITOR" {
    try std.testing.expectEqualStrings("code --wait", resolveCommand("code --wait", "vim", "nano").?);
    try std.testing.expectEqualStrings("vim", resolveCommand(null, " vim ", "nano").?);
    try std.testing.expectEqualStrings("nano", resolveCommand(null, "  ", "nano").?);
    try std.testing.expect(resolveCommand(null, null, "") == null);
}

test "an editor command with flags becomes separate arguments followed by the draft file" {
    const alloc = std.testing.allocator;
    const argv = try argvFor(alloc, "code  --wait", "/tmp/fx-draft-7.md");
    defer alloc.free(argv);
    try std.testing.expectEqual(@as(usize, 3), argv.len);
    try std.testing.expectEqualStrings("code", argv[0]);
    try std.testing.expectEqualStrings("--wait", argv[1]);
    try std.testing.expectEqualStrings("/tmp/fx-draft-7.md", argv[2]);
}

test "the draft file is named by time under the temp directory and its trailing newline is dropped" {
    const alloc = std.testing.allocator;
    const path = try draftPath(alloc, "/var/tmp/", 1700);
    defer alloc.free(path);
    try std.testing.expectEqualStrings("/var/tmp/fx-draft-1700.md", path);
    try std.testing.expectEqualStrings("fix the parser\n\nand the tests", draftText("fix the parser\n\nand the tests\n"));
}

test "an editor chosen with /editor lasts for the process and a blank choice clears it" {
    try chooseForSession("");
    try std.testing.expect(sessionCommand() == null);
    try chooseForSession("  hx ");
    try std.testing.expectEqualStrings("hx", sessionCommand().?);
    try chooseForSession("");
    try std.testing.expect(sessionCommand() == null);
}
