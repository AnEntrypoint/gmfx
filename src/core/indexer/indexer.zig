const std = @import("std");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const git_config = @import("git_config.zig");
const layout = @import("layout.zig");
const scan_mod = @import("scan.zig");
const snapshot_mod = @import("snapshot.zig");
const tree_mod = @import("tree.zig");

const Allocator = std.mem.Allocator;

pub const Kind = scan_mod.Kind;
pub const Entry = scan_mod.Entry;
pub const ScanResult = scan_mod.Result;
pub const ScanError = scan_mod.Error;
pub const default_skipped_names = scan_mod.default_skipped_names;
pub const config_environment_names = git_config.environment_names;

pub const scan = scan_mod.scan;

pub const Tree = tree_mod.Tree;
pub const FolderStamp = tree_mod.FolderStamp;
pub const isCurrent = tree_mod.isCurrent;

pub const Snapshot = snapshot_mod.Snapshot;
pub const loadSnapshot = snapshot_mod.load;
pub const saveSnapshot = snapshot_mod.save;

pub const RepoFilters = struct {
    git_dir: ?[]const u8,
    names: []const []const u8,

    pub fn deinit(self: RepoFilters, alloc: Allocator) void {
        if (self.git_dir) |git_dir| alloc.free(git_dir);
        for (self.names) |name| alloc.free(name);
        alloc.free(self.names);
    }
};

pub const RepoFiltersError = error{ OutOfMemory, RepoConfigUnavailable };

pub fn repoFilters(alloc: Allocator, workspace_root: []const u8) RepoFiltersError!RepoFilters {
    if (!std.Io.Dir.path.isAbsolute(workspace_root)) return error.RepoConfigUnavailable;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const found = layout.discover(arena, workspace_root) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidGitFile => {
            debug_trace.logf("indexer", "filter names unavailable reason=invalid_git_file root={s}", .{workspace_root});
            return error.RepoConfigUnavailable;
        },
    };
    const context = try git_config.Context.fromEnvironment(arena, found);
    const loaded = try git_config.loadRepositoryEveryInclude(arena, &context);
    if (loaded.unavailable.len > 0) {
        for (loaded.unavailable) |source| {
            debug_trace.logf("indexer", "filter names unavailable reason={s} path={s}", .{ source.reason, source.path });
        }
        return error.RepoConfigUnavailable;
    }

    const names = try git_config.filterDriverNames(arena, loaded);
    const git_dir: ?[]const u8 = if (found) |repository| try alloc.dupe(u8, repository.git_dir) else null;
    errdefer if (git_dir) |path| alloc.free(path);
    const owned = try alloc.alloc([]const u8, names.len);
    var copied: usize = 0;
    errdefer {
        for (owned[0..copied]) |name| alloc.free(name);
        alloc.free(owned);
    }
    for (names) |name| {
        owned[copied] = try alloc.dupe(u8, name);
        copied += 1;
    }
    return .{ .git_dir = git_dir, .names = owned };
}

test {
    _ = @import("bounded_read.zig");
    _ = @import("wildmatch.zig");
    _ = @import("ignore.zig");
    _ = @import("sources.zig");
    _ = @import("git_index.zig");
    _ = tree_mod;
    _ = snapshot_mod;
    _ = scan_mod;
    _ = layout;
    _ = git_config;
}

fn writeTestFile(dir: std.Io.Dir, path: []const u8, content: []const u8) !void {
    if (std.Io.Dir.path.dirname(path)) |parent| try dir.createDirPath(std.testing.io, parent);
    try dir.writeFile(std.testing.io, .{ .sub_path = path, .data = content });
}

fn makeTestRepo(dir: std.Io.Dir, name: []const u8) !void {
    var buffer: [64]u8 = undefined;
    try writeTestFile(dir, try std.mem.print(&buffer, "{s}/.git/HEAD", .{name}), "ref: refs/heads/main\n");
    try dir.createDirPath(std.testing.io, try std.mem.print(&buffer, "{s}/.git/objects", .{name}));
    try dir.createDirPath(std.testing.io, try std.mem.print(&buffer, "{s}/.git/refs", .{name}));
}

test "repoFilters returns the repository and its drivers and fails closed on unreadable config" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeTestRepo(tmp.dir, "repo");
    try writeTestFile(tmp.dir, "repo/.git/config", "[includeIf \"gitdir:/nowhere/\"]\npath = extra\n");
    try writeTestFile(tmp.dir, "repo/.git/extra", "[filter \"x\"]\nclean = /tmp/run-me\n");
    try tmp.dir.createDirPath(std.testing.io, "repo/src");
    try makeTestRepo(tmp.dir, "bad");
    try tmp.dir.createDirPath(std.testing.io, "bad/.git/config");
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);

    const repo_src = try std.Io.Dir.path.join(alloc, &.{ root, "repo/src" });
    defer alloc.free(repo_src);
    const filters = try repoFilters(alloc, repo_src);
    defer filters.deinit(alloc);
    const expected_git_dir = try std.Io.Dir.path.join(alloc, &.{ root, "repo/.git" });
    defer alloc.free(expected_git_dir);
    try std.testing.expectEqualStrings(expected_git_dir, filters.git_dir.?);
    try std.testing.expectEqual(@as(usize, 1), filters.names.len);
    try std.testing.expectEqualStrings("x", filters.names[0]);

    const bad = try std.Io.Dir.path.join(alloc, &.{ root, "bad" });
    defer alloc.free(bad);
    try std.testing.expectError(error.RepoConfigUnavailable, repoFilters(alloc, bad));
    try std.testing.expectError(error.RepoConfigUnavailable, repoFilters(alloc, "relative"));
}
