const std = @import("std");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;

pub const max_lines: usize = 64;
pub const max_line_bytes: usize = 512;
const max_gitignore_bytes: usize = 1024 * 1024;

pub const Problem = enum {
    empty,
    too_long,
    line_break,
    absolute,
    parent_segment,
    negation,

    pub fn reason(self: Problem) []const u8 {
        return switch (self) {
            .empty => "an ignore line is empty",
            .too_long => "an ignore line is longer than 512 bytes",
            .line_break => "an ignore line contains a line break",
            .absolute => "ignore lines must be relative paths, not absolute",
            .parent_segment => "ignore lines must not contain a .. segment",
            .negation => "ignore lines must not start with !, which would stop ignoring a path",
        };
    }
};

pub fn problemOf(line: []const u8) ?Problem {
    if (std.mem.findAny(u8, line, "\r\n") != null) return .line_break;
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return .empty;
    if (trimmed.len > max_line_bytes) return .too_long;
    if (trimmed[0] == '!') return .negation;
    if (trimmed[0] == '/' or trimmed[0] == '\\') return .absolute;
    if (trimmed.len >= 2 and std.ascii.isAlphabetic(trimmed[0]) and trimmed[1] == ':') return .absolute;
    var segments = std.mem.tokenizeAny(u8, trimmed, "/\\");
    while (segments.next()) |segment| {
        if (std.mem.eql(u8, segment, "..")) return .parent_segment;
    }
    return null;
}

pub fn firstProblem(lines: []const []const u8) ?Problem {
    for (lines) |line| {
        if (problemOf(line)) |problem| return problem;
    }
    return null;
}

fn present(existing: []const u8, wanted: []const u8) bool {
    var lines = std.mem.splitScalar(u8, existing, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, std.mem.trim(u8, line, " \t\r"), wanted)) return true;
    }
    return false;
}

pub fn merged(alloc: Allocator, existing: []const u8, wanted: []const []const u8) Allocator.Error!?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, existing);
    const eol: []const u8 = if (std.mem.find(u8, existing, "\r\n") != null) "\r\n" else "\n";
    var added: usize = 0;
    for (wanted, 0..) |raw, index| {
        const line = std.mem.trim(u8, raw, " \t");
        if (problemOf(raw) != null or present(existing, line)) continue;
        const repeated = for (wanted[0..index]) |earlier| {
            if (std.mem.eql(u8, std.mem.trim(u8, earlier, " \t"), line)) break true;
        } else false;
        if (repeated) continue;
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.appendSlice(alloc, eol);
        try out.appendSlice(alloc, line);
        try out.appendSlice(alloc, eol);
        added += 1;
    }
    if (added == 0) {
        out.deinit(alloc);
        return null;
    }
    return try out.toOwnedSlice(alloc);
}

pub const Outcome = enum { unchanged, added, not_a_repository };

pub fn apply(alloc: Allocator, workspace_root: []const u8, wanted: []const []const u8) !Outcome {
    if (wanted.len == 0) return .unchanged;
    if (!std.Io.Dir.path.isAbsolute(workspace_root)) return .not_a_repository;
    const io = io_mod.getIo();
    const git_path = try std.Io.Dir.path.join(alloc, &.{ workspace_root, ".git" });
    defer alloc.free(git_path);
    std.Io.Dir.accessAbsolute(io, git_path, .{}) catch return .not_a_repository;

    const ignore_path = try std.Io.Dir.path.join(alloc, &.{ workspace_root, ".gitignore" });
    defer alloc.free(ignore_path);
    const existing: []u8 = read: {
        var file = std.Io.Dir.openFileAbsolute(io, ignore_path, .{}) catch |err| switch (err) {
            error.FileNotFound => break :read try alloc.alloc(u8, 0),
            else => return err,
        };
        defer file.close(io);
        break :read try io_mod.readFileToEnd(alloc, &file, max_gitignore_bytes);
    };
    defer alloc.free(existing);

    const next = (try merged(alloc, existing, wanted)) orelse return .unchanged;
    defer alloc.free(next);
    try io_mod.writeFileAtomic(alloc, ignore_path, next);
    return .added;
}

test "MCP ignore lines must be relative, stay inside the workspace and never re-include a path" {
    try std.testing.expectEqual(@as(?Problem, null), problemOf(".server-state/"));
    try std.testing.expectEqual(@as(?Problem, null), problemOf("cache/*.log"));
    try std.testing.expectEqual(@as(?Problem, null), problemOf("notes..md"));
    try std.testing.expectEqual(Problem.empty, problemOf("  ").?);
    try std.testing.expectEqual(Problem.absolute, problemOf("/etc/passwd").?);
    try std.testing.expectEqual(Problem.absolute, problemOf("\\share").?);
    try std.testing.expectEqual(Problem.absolute, problemOf("C:\\state").?);
    try std.testing.expectEqual(Problem.parent_segment, problemOf("../outside").?);
    try std.testing.expectEqual(Problem.parent_segment, problemOf("a/../../b").?);
    try std.testing.expectEqual(Problem.line_break, problemOf("a\nb").?);
    try std.testing.expectEqual(Problem.negation, problemOf("!src/").?);
    try std.testing.expectEqual(Problem.parent_segment, firstProblem(&.{ "ok/", "x/.." }).?);
    try std.testing.expectEqual(@as(?Problem, null), firstProblem(&.{ "ok/", "also-ok" }));
}

test "MCP ignore lines are appended after the existing lines, once, and nothing is removed" {
    const alloc = std.testing.allocator;
    const first = (try merged(alloc, "node_modules/\n*.log", &.{ ".state/", "*.log", ".state/", " cache/ " })).?;
    defer alloc.free(first);
    try std.testing.expectEqualStrings("node_modules/\n*.log\n.state/\ncache/\n", first);
    try std.testing.expectEqual(@as(?[]u8, null), try merged(alloc, first, &.{ ".state/", "cache/" }));

    const fresh = (try merged(alloc, "", &.{".state/"})).?;
    defer alloc.free(fresh);
    try std.testing.expectEqualStrings(".state/\n", fresh);

    const windows = (try merged(alloc, "a\r\nb\r\n", &.{"c"})).?;
    defer alloc.free(windows);
    try std.testing.expectEqualStrings("a\r\nb\r\nc\r\n", windows);
}

test "MCP ignore lines are written only in a git repository and a second apply changes nothing" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);

    try std.testing.expectEqual(Outcome.not_a_repository, try apply(alloc, root, &.{".state/"}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, ".gitignore", .{}));

    try tmp.dir.createDirPath(std.testing.io, ".git");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".gitignore", .data = "dist/\n" });
    try std.testing.expectEqual(Outcome.added, try apply(alloc, root, &.{".state/"}));
    try std.testing.expectEqual(Outcome.unchanged, try apply(alloc, root, &.{".state/"}));
    try std.testing.expectEqual(Outcome.unchanged, try apply(alloc, root, &.{}));

    var file = try tmp.dir.openFile(std.testing.io, ".gitignore", .{});
    defer file.close(std.testing.io);
    const text = try io_mod.readFileToEnd(alloc, &file, 4096);
    defer alloc.free(text);
    try std.testing.expectEqualStrings("dist/\n.state/\n", text);
}
