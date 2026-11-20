const std = @import("std");
const git_context = @import("git_context.zig");

const Allocator = std.mem.Allocator;

pub const Outcome = struct {
    ok: bool,
    text: []u8,
};

const Report = struct {
    command: []const u8,
    ok: bool,
    read_only: bool,
    offline: bool,
    @"error": []const u8,
    in_git_repo: bool,
    branch: []const u8,
    head: []const u8,
    clean: bool,
    changes: []const []const u8,
    recent_commits: []const []const u8,
    staged_stat: []const u8,
    unstaged_stat: []const u8,
};

pub fn json(alloc: Allocator) !Outcome {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const captured = try git_context.state(arena);
    const error_code: []const u8 = if (captured.refused)
        "git_refused"
    else if (!captured.in_git_repo)
        "not_a_git_repository"
    else
        "";
    const changes = try lines(arena, captured.status, true);
    const report = Report{
        .command = "git-snapshot",
        .ok = error_code.len == 0,
        .read_only = true,
        .offline = true,
        .@"error" = error_code,
        .in_git_repo = captured.in_git_repo,
        .branch = captured.branch orelse "",
        .head = captured.head orelse "",
        .clean = error_code.len == 0 and changes.len == 0,
        .changes = changes,
        .recent_commits = try lines(arena, captured.log, false),
        .staged_stat = captured.staged orelse "",
        .unstaged_stat = captured.unstaged orelse "",
    };
    const text = try std.json.Stringify.valueAlloc(arena, report, .{});
    return .{ .ok = report.ok, .text = try alloc.dupe(u8, text) };
}

fn lines(arena: Allocator, text: ?[]const u8, skip_branch_header: bool) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const body = text orelse return out.items;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        if (skip_branch_header and std.mem.startsWith(u8, line, "## ")) continue;
        try out.append(arena, line);
    }
    return out.items;
}
