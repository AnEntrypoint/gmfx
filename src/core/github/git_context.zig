const std = @import("std");
const testing_allocator = @import("../shared/testing_allocator.zig");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const safe_git = @import("../shell_command/safe_git.zig");

const Allocator = std.mem.Allocator;

pub const Snapshot = struct {
    in_git_repo: bool,
    text: []u8,

    pub fn deinit(self: Snapshot, alloc: Allocator) void {
        alloc.free(self.text);
    }
};

const Query = struct {
    subcommand: safe_git.Subcommand,
    args: []const []const u8,
};

const branch_query: Query = .{ .subcommand = .branch, .args = &.{"--show-current"} };
const status_query: Query = .{ .subcommand = .status, .args = &.{ "--short", "--branch" } };
const log_query: Query = .{ .subcommand = .log, .args = &.{ "--oneline", "-5" } };
const staged_query: Query = .{ .subcommand = .diff, .args = &.{ "--stat", "--cached" } };
const unstaged_query: Query = .{ .subcommand = .diff, .args = &.{"--stat"} };
const inside_query: Query = .{ .subcommand = .rev_parse, .args = &.{"--is-inside-work-tree"} };
const head_query: Query = .{ .subcommand = .rev_parse, .args = &.{"HEAD"} };
const snapshot_queries = [_]Query{ branch_query, status_query, log_query, staged_query, unstaged_query, inside_query, head_query };

pub const State = struct {
    refused: bool = false,
    in_git_repo: bool = false,
    branch: ?[]u8 = null,
    head: ?[]u8 = null,
    status: ?[]u8 = null,
    log: ?[]u8 = null,
    staged: ?[]u8 = null,
    unstaged: ?[]u8 = null,

    pub fn deinit(self: State, alloc: Allocator) void {
        freeText(alloc, self.branch);
        freeText(alloc, self.head);
        freeText(alloc, self.status);
        freeText(alloc, self.log);
        freeText(alloc, self.staged);
        freeText(alloc, self.unstaged);
    }
};

fn freeText(alloc: Allocator, text: ?[]u8) void {
    if (text) |owned| alloc.free(owned);
}

pub fn state(alloc: Allocator) !State {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const ready = switch (try prepareHere(arena_state.allocator())) {
        .ready => |ready| ready,
        .refused => return .{ .refused = true },
    };

    var result: State = .{};
    errdefer result.deinit(alloc);
    result.branch = try runGit(alloc, ready, branch_query);
    result.head = try runGit(alloc, ready, head_query);
    result.status = try runGit(alloc, ready, status_query);
    result.log = try runGit(alloc, ready, log_query);
    result.staged = try runGit(alloc, ready, staged_query);
    result.unstaged = try runGit(alloc, ready, unstaged_query);
    result.in_git_repo = isGitRepository(alloc, ready);
    return result;
}

pub fn snapshot(alloc: Allocator) !Snapshot {
    const captured = try state(alloc);
    defer captured.deinit(alloc);
    if (captured.refused) return .{
        .in_git_repo = true,
        .text = try formatSnapshot(alloc, null, null, null, null, null),
    };
    return .{
        .in_git_repo = captured.in_git_repo,
        .text = try formatSnapshot(alloc, captured.branch, captured.status, captured.log, captured.staged, captured.unstaged),
    };
}

const short_status_query: Query = .{ .subcommand = .status, .args = &.{"--short"} };
const head_stat_query: Query = .{ .subcommand = .diff, .args = &.{ "--stat", "HEAD" } };
const head_patch_query: Query = .{ .subcommand = .diff, .args = &.{"HEAD"} };
const working_tree_patch_limit: usize = 48 * 1024;
const working_tree_unavailable = "git is unavailable here, so fx cannot show the working tree changes.";
const working_tree_not_a_repo = "This directory is not inside a git repository.";
const working_tree_clean = "No uncommitted changes in the working tree.";
const working_tree_patch_omitted = "The full patch is too large to show here; run `git diff HEAD` to read it.";

pub fn workingTreeDiff(alloc: Allocator) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const ready = switch (try prepareHere(arena_state.allocator())) {
        .ready => |ready| ready,
        .refused => return alloc.dupe(u8, working_tree_unavailable),
    };
    if (!isGitRepository(alloc, ready)) return alloc.dupe(u8, working_tree_not_a_repo);

    const status = try runGitBounded(alloc, ready, short_status_query, working_tree_patch_limit);
    defer freeText(alloc, status);
    const stat = try runGitBounded(alloc, ready, head_stat_query, working_tree_patch_limit);
    defer freeText(alloc, stat);
    const patch = try runGitBounded(alloc, ready, head_patch_query, working_tree_patch_limit);
    defer freeText(alloc, patch);
    return formatWorkingTreeDiff(alloc, status, stat, patch);
}

fn runGitBounded(alloc: Allocator, ready: safe_git.Ready, query: Query, stdout_limit: usize) !?[]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var environment = try safe_git.environment(arena);

    const result = std.process.run(alloc, io_mod.getIo(), .{
        .argv = try buildGitArgv(arena, ready, query),
        .environ_map = &environment,
        .stdout_limit = .limited(stdout_limit),
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer alloc.free(result.stderr);
    defer alloc.free(result.stdout);
    if (result.term != .exited or result.term.exited != 0) return null;
    const trimmed = std.mem.trim(u8, result.stdout, "\r\n");
    if (trimmed.len == 0) return null;
    return try alloc.dupe(u8, trimmed);
}

fn formatWorkingTreeDiff(alloc: Allocator, status: ?[]const u8, stat: ?[]const u8, patch: ?[]const u8) ![]u8 {
    if (status == null and stat == null and patch == null) return alloc.dupe(u8, working_tree_clean);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    if (status) |files| {
        try out.writer.writeAll("Changed files:\n");
        try writeBody(&out.writer, files, "");
    }
    if (stat) |summary| {
        if (status != null) try out.writer.writeByte('\n');
        try writeBody(&out.writer, summary, "");
    }
    if (patch) |text| {
        try out.writer.writeByte('\n');
        try writeBody(&out.writer, text, "");
    } else if (stat != null) {
        try out.writer.writeByte('\n');
        try out.writer.writeAll(working_tree_patch_omitted);
        try out.writer.writeByte('\n');
    }
    return try out.toOwnedSlice();
}

test "the working tree diff lists changed files, then the stat, then the patch, and says when the patch is left out" {
    const alloc = std.testing.allocator;

    const clean = try formatWorkingTreeDiff(alloc, null, null, null);
    defer alloc.free(clean);
    try std.testing.expectEqualStrings(working_tree_clean, clean);

    const full = try formatWorkingTreeDiff(alloc, " M src/a.zig\n?? notes.txt", " src/a.zig | 2 +-", "diff --git a/src/a.zig b/src/a.zig\n-old\n+new");
    defer alloc.free(full);
    try std.testing.expectEqualStrings(
        "Changed files:\n M src/a.zig\n?? notes.txt\n\n src/a.zig | 2 +-\n\ndiff --git a/src/a.zig b/src/a.zig\n-old\n+new\n",
        full,
    );

    const large = try formatWorkingTreeDiff(alloc, " M src/a.zig", " src/a.zig | 9000 +++++", null);
    defer alloc.free(large);
    try std.testing.expect(std.mem.endsWith(u8, large, working_tree_patch_omitted ++ "\n"));

    const untracked_only = try formatWorkingTreeDiff(alloc, "?? notes.txt", null, null);
    defer alloc.free(untracked_only);
    try std.testing.expectEqualStrings("Changed files:\n?? notes.txt\n", untracked_only);
}

const explore_dirty_limit = 20;
const explore_commit_limit = 3;
const explore_line_limit = 200;
const not_a_repo_context = "<git-context status=\"unavailable\" reason=\"not-a-repo\"/>";

pub fn explorePrefix(alloc: Allocator) ![]u8 {
    const captured = try state(alloc);
    defer captured.deinit(alloc);
    if (captured.refused) return alloc.dupe(u8, "");
    if (!captured.in_git_repo) return alloc.dupe(u8, not_a_repo_context);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const cwd = io_mod.realpathAlloc(arena_state.allocator(), ".") catch ".";
    return formatExplorePrefix(alloc, cwd, captured);
}

fn formatExplorePrefix(alloc: Allocator, cwd: []const u8, captured: State) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var dirty: std.ArrayList([]const u8) = .empty;
    if (captured.status) |status| {
        var lines = std.mem.splitScalar(u8, status, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, " \t\r");
            if (line.len == 0 or std.mem.startsWith(u8, line, "## ")) continue;
            try dirty.append(arena, line);
        }
    }

    var body: std.Io.Writer.Allocating = .init(alloc);
    defer body.deinit();
    const writer = &body.writer;
    var sections: usize = 0;
    try writer.print("Working directory: {s}\n", .{cwd});
    if (captured.branch) |branch| {
        if (branch.len > 0) {
            try writer.print("Branch: {s}\n", .{branch});
            sections += 1;
        }
    }
    if (dirty.items.len > 0) {
        try writer.print("Dirty files ({d}):\n", .{dirty.items.len});
        for (dirty.items[0..@min(dirty.items.len, explore_dirty_limit)]) |line| try writer.print("  {s}\n", .{line});
        if (dirty.items.len > explore_dirty_limit) try writer.print("  ... and {d} more\n", .{dirty.items.len - explore_dirty_limit});
        sections += 1;
    }
    if (captured.log) |log| {
        var commits: usize = 0;
        var lines = std.mem.splitScalar(u8, log, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;
            if (commits == explore_commit_limit) break;
            if (commits == 0) try writer.writeAll("Recent commits:\n");
            try writer.print("  {s}\n", .{line[0..@min(line.len, explore_line_limit)]});
            commits += 1;
        }
        if (commits > 0) sections += 1;
    }
    if (sections == 0) return alloc.dupe(u8, "");

    const text = try body.toOwnedSlice();
    defer alloc.free(text);
    return alloc.print("<git-context>\n{s}</git-context>", .{text});
}

fn prepareHere(arena: Allocator) Allocator.Error!safe_git.Prepared {
    const cwd = io_mod.realpathAlloc(arena, ".") catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            debug_trace.logf("core", "git snapshot unavailable reason=cwd_unresolved error={s}", .{@errorName(err)});
            return .{ .refused = .repo_config_unavailable };
        },
    };
    return safe_git.prepare(arena, cwd);
}

fn buildGitArgv(arena: Allocator, ready: safe_git.Ready, query: Query) Allocator.Error![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try safe_git.appendCommand(arena, &argv, ready, query.subcommand);
    try argv.appendSlice(arena, query.args);
    return argv.items;
}

fn isGitRepository(alloc: Allocator, ready: safe_git.Ready) bool {
    const result = runGit(alloc, ready, inside_query) catch return false;
    defer if (result) |text| alloc.free(text);
    return if (result) |text| std.mem.eql(u8, text, "true") else false;
}

fn runGit(alloc: Allocator, ready: safe_git.Ready, query: Query) !?[]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var environment = try safe_git.environment(arena);

    const result = std.process.run(alloc, io_mod.getIo(), .{
        .argv = try buildGitArgv(arena, ready, query),
        .environ_map = &environment,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer alloc.free(result.stderr);
    errdefer alloc.free(result.stdout);

    if (result.term.exited != 0) {
        alloc.free(result.stdout);
        return null;
    }

    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == 0) {
        alloc.free(result.stdout);
        return null;
    }
    if (trimmed.len == result.stdout.len) return result.stdout;

    const owned = try alloc.dupe(u8, trimmed);
    alloc.free(result.stdout);
    return owned;
}

fn formatSnapshot(
    alloc: Allocator,
    branch: ?[]const u8,
    status: ?[]const u8,
    log: ?[]const u8,
    staged: ?[]const u8,
    unstaged: ?[]const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("Git snapshot\n");
    try out.writer.print("Branch: {s}\n", .{branch orelse "unavailable"});
    try out.writer.writeAll("\nStatus:\n");
    try writeBody(&out.writer, status, "unavailable");
    try out.writer.writeAll("\nRecent commits:\n");
    try writeBody(&out.writer, log, "unavailable");
    try out.writer.writeAll("\nStaged diff stat:\n");
    try writeBody(&out.writer, staged, "none");
    try out.writer.writeAll("\nUnstaged diff stat:\n");
    try writeBody(&out.writer, unstaged, "none");

    return try out.toOwnedSlice();
}

fn writeBody(writer: *std.Io.Writer, value: ?[]const u8, fallback: []const u8) !void {
    const body = value orelse fallback;
    try writer.writeAll(body);
    if (body.len == 0 or body[body.len - 1] != '\n') try writer.writeByte('\n');
}

test "snapshot formatting: null git values match core fallback text exactly" {
    const text = try formatSnapshot(std.testing.allocator, null, null, null, null, null);
    defer std.testing.allocator.free(text);

    try std.testing.expectEqualStrings(
        \\Git snapshot
        \\Branch: unavailable
        \\
        \\Status:
        \\unavailable
        \\
        \\Recent commits:
        \\unavailable
        \\
        \\Staged diff stat:
        \\none
        \\
        \\Unstaged diff stat:
        \\none
        \\
    , text);
}

test "snapshot formatting: populated sections preserve layout exactly" {
    const text = try formatSnapshot(
        std.testing.allocator,
        "main",
        "## main\n M src/main.zig",
        "abc123 first\n",
        " src/main.zig | 2 ++",
        " src/core/github/git_context.zig | 5 +++++",
    );
    defer std.testing.allocator.free(text);

    try std.testing.expectEqualStrings(
        \\Git snapshot
        \\Branch: main
        \\
        \\Status:
        \\## main
        \\ M src/main.zig
        \\
        \\Recent commits:
        \\abc123 first
        \\
        \\Staged diff stat:
        \\ src/main.zig | 2 ++
        \\
        \\Unstaged diff stat:
        \\ src/core/github/git_context.zig | 5 +++++
        \\
    , text);
}

test "git argv: every snapshot command is built by the safe-git helper" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ready: safe_git.Ready = .{ .executable = "/usr/bin/git", .filter_names = &.{"x"} };

    for (snapshot_queries) |query| {
        var prefix: std.ArrayList([]const u8) = .empty;
        try safe_git.appendCommand(arena, &prefix, ready, query.subcommand);
        const argv = try buildGitArgv(arena, ready, query);
        try std.testing.expectEqual(prefix.items.len + query.args.len, argv.len);
        for (prefix.items, argv[0..prefix.items.len]) |want, have| try std.testing.expectEqualStrings(want, have);
        for (query.args, argv[prefix.items.len..]) |want, have| try std.testing.expectEqualStrings(want, have);
    }
}

test "git repository detection treats allocation failure as unavailable" {
    var failing = std.testing.FailingAllocator.init(testing_allocator.no_resize, .{ .fail_index = 0 });
    const ready: safe_git.Ready = .{ .executable = "/usr/bin/git", .filter_names = &.{} };
    try std.testing.expect(!isGitRepository(failing.allocator(), ready));
}

test "snapshot returns owned Git status text" {
    const snap = try snapshot(std.testing.allocator);
    defer snap.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.find(u8, snap.text, "Git snapshot") != null);
    try std.testing.expect(std.mem.find(u8, snap.text, "Branch:") != null);
}

test "explore prefix lists branch, dirty files and recent commits in a git-context block" {
    const alloc = std.testing.allocator;
    const captured: State = .{
        .in_git_repo = true,
        .branch = @constCast("main"),
        .status = @constCast("## main...origin/main\n M src/a.zig\n?? notes.txt\n"),
        .log = @constCast("abc1234 first\ndef5678 second\nfeed999 third\nbeef000 fourth\n"),
    };
    const text = try formatExplorePrefix(alloc, "/repo", captured);
    defer alloc.free(text);
    try std.testing.expectEqualStrings(
        "<git-context>\n" ++
            "Working directory: /repo\n" ++
            "Branch: main\n" ++
            "Dirty files (2):\n" ++
            "   M src/a.zig\n" ++
            "  ?? notes.txt\n" ++
            "Recent commits:\n" ++
            "  abc1234 first\n" ++
            "  def5678 second\n" ++
            "  feed999 third\n" ++
            "</git-context>",
        text,
    );
}

test "explore prefix is empty when the repository has nothing to report" {
    const alloc = std.testing.allocator;
    const text = try formatExplorePrefix(alloc, "/repo", .{ .in_git_repo = true });
    defer alloc.free(text);
    try std.testing.expectEqualStrings("", text);
}
