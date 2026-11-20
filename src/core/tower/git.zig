const std = @import("std");
const io_mod = @import("../shared/io.zig");
const paths = @import("paths.zig");

const Allocator = std.mem.Allocator;

const fallback_identity = [_][]const u8{
    "-c",
    "user.name=fx",
    "-c",
    "user.email=fx@localhost",
};
const add_paths_chunk = 100;

pub const Output = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: ?u8,

    pub fn deinit(self: Output, alloc: Allocator) void {
        alloc.free(self.stdout);
        alloc.free(self.stderr);
    }
};

pub fn execute(alloc: Allocator, cwd: []const u8, args: []const []const u8) !Output {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    try argv.append(alloc, "git");
    try argv.appendSlice(alloc, args);
    const result = try std.process.run(alloc, io_mod.getIo(), .{
        .argv = argv.items,
        .cwd = .{ .path = cwd },
    });
    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .exit_code = switch (result.term) {
            .exited => |code| code,
            else => null,
        },
    };
}

pub fn run(alloc: Allocator, cwd: []const u8, args: []const []const u8) ![]u8 {
    const output = try execute(alloc, cwd, args);
    defer alloc.free(output.stderr);
    if (output.exit_code != 0) {
        alloc.free(output.stdout);
        return error.GitFailed;
    }
    const trimmed = std.mem.trimEnd(u8, output.stdout, " \t\r\n");
    const owned = try alloc.dupe(u8, trimmed);
    alloc.free(output.stdout);
    return owned;
}

fn expectSuccess(alloc: Allocator, cwd: []const u8, args: []const []const u8) !void {
    const out = try run(alloc, cwd, args);
    alloc.free(out);
}

pub fn currentBranch(alloc: Allocator, cwd: []const u8) ![]u8 {
    const branch = try run(alloc, cwd, &.{ "rev-parse", "--abbrev-ref", "HEAD" });
    errdefer alloc.free(branch);
    if (std.mem.eql(u8, branch, "HEAD")) return error.DetachedHead;
    return branch;
}

pub fn branchTip(alloc: Allocator, cwd: []const u8, reference: []const u8) ![]u8 {
    return run(alloc, cwd, &.{ "rev-parse", reference });
}

pub fn branchExists(alloc: Allocator, cwd: []const u8, branch: []const u8) !bool {
    const ref = try std.fmt.allocPrint(alloc, "refs/heads/{s}", .{branch});
    defer alloc.free(ref);
    const output = try execute(alloc, cwd, &.{ "show-ref", "--verify", "--quiet", ref });
    defer output.deinit(alloc);
    const code = output.exit_code orelse return error.GitFailed;
    if (code == 0) return true;
    if (code == 1) return false;
    return error.GitFailed;
}

pub fn isAncestor(alloc: Allocator, cwd: []const u8, ancestor: []const u8, reference: []const u8) !bool {
    const output = try execute(alloc, cwd, &.{ "merge-base", "--is-ancestor", ancestor, reference });
    defer output.deinit(alloc);
    const code = output.exit_code orelse return error.GitFailed;
    if (code == 0) return true;
    if (code == 1) return false;
    return error.GitFailed;
}

pub fn checkoutNewLocalBranch(alloc: Allocator, cwd: []const u8, branch: []const u8) !void {
    try expectSuccess(alloc, cwd, &.{ "checkout", "-b", branch });
}

fn absolutePath(alloc: Allocator, path: []const u8) ![]u8 {
    if (std.Io.Dir.path.isAbsolute(path)) return alloc.dupe(u8, path);
    const cwd = try std.process.currentPathAlloc(io_mod.getIo(), alloc);
    defer alloc.free(cwd);
    return std.Io.Dir.path.join(alloc, &.{ cwd, path });
}

pub fn worktreeAddNewBranch(alloc: Allocator, cwd: []const u8, path: []const u8, branch: []const u8, base: []const u8) !void {
    const absolute = try absolutePath(alloc, path);
    defer alloc.free(absolute);
    try expectSuccess(alloc, cwd, &.{ "worktree", "add", absolute, "-b", branch, base });
}

pub fn worktreeAdd(alloc: Allocator, cwd: []const u8, path: []const u8, branch: []const u8) !void {
    const absolute = try absolutePath(alloc, path);
    defer alloc.free(absolute);
    try expectSuccess(alloc, cwd, &.{ "worktree", "add", absolute, branch });
}

pub fn worktreeRemove(alloc: Allocator, cwd: []const u8, path: []const u8) !void {
    const absolute = try absolutePath(alloc, path);
    defer alloc.free(absolute);
    try expectSuccess(alloc, cwd, &.{ "worktree", "remove", "--force", absolute });
}

pub fn isWorktreeDirty(alloc: Allocator, path: []const u8) !bool {
    const status = try run(alloc, path, &.{ "status", "--porcelain" });
    defer alloc.free(status);
    return status.len > 0;
}

pub fn commitAllowEmpty(alloc: Allocator, cwd: []const u8, message: []const u8) !void {
    try commitWithIdentity(alloc, cwd, &.{ "commit", "--allow-empty", "-m", message });
}

pub fn commitPaths(alloc: Allocator, cwd: []const u8, file_paths: []const []const u8, message: []const u8) !void {
    var start: usize = 0;
    while (start < file_paths.len) : (start += add_paths_chunk) {
        const end = @min(start + add_paths_chunk, file_paths.len);
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(alloc);
        try argv.appendSlice(alloc, &.{ "add", "-A", "--" });
        try argv.appendSlice(alloc, file_paths[start..end]);
        try expectSuccess(alloc, cwd, argv.items);
    }
    try commitWithIdentity(alloc, cwd, &.{ "commit", "-m", message });
}

fn commitWithIdentity(alloc: Allocator, cwd: []const u8, args: []const []const u8) !void {
    const output = try execute(alloc, cwd, args);
    defer output.deinit(alloc);
    if (output.exit_code == 0) return;
    if (std.mem.indexOf(u8, output.stderr, "identity unknown") == null) return error.GitFailed;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    try argv.appendSlice(alloc, &fallback_identity);
    try argv.appendSlice(alloc, args);
    try expectSuccess(alloc, cwd, argv.items);
}

fn hasConfiguredIdentity(alloc: Allocator, cwd: []const u8) !bool {
    for ([_][]const u8{ "GIT_AUTHOR_IDENT", "GIT_COMMITTER_IDENT" }) |ident| {
        const output = try execute(alloc, cwd, &.{ "var", ident });
        defer output.deinit(alloc);
        if (output.exit_code != 0) return false;
    }
    return true;
}

fn hasMergeHead(alloc: Allocator, cwd: []const u8) !bool {
    const output = try execute(alloc, cwd, &.{ "rev-parse", "--verify", "--quiet", "MERGE_HEAD" });
    defer output.deinit(alloc);
    const code = output.exit_code orelse return error.GitFailed;
    if (code == 0) return true;
    if (code == 1) return false;
    return error.GitFailed;
}

pub fn mergeNoFf(alloc: Allocator, cwd: []const u8, revision: []const u8, message: ?[]const u8) ![]u8 {
    if (try hasMergeHead(alloc, cwd)) return error.MergeHeadExists;
    const head_before = try branchTip(alloc, cwd, "HEAD");
    defer alloc.free(head_before);
    const status_before = try run(alloc, cwd, &.{ "status", "--porcelain" });
    defer alloc.free(status_before);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    try argv.appendSlice(alloc, &.{ "merge", "--no-ff" });
    if (message) |text| try argv.appendSlice(alloc, &.{ "-m", text });
    try argv.append(alloc, revision);

    const merge_output = try execute(alloc, cwd, argv.items);
    defer merge_output.deinit(alloc);
    if (merge_output.exit_code != 0) {
        const left_behind = hasMergeHead(alloc, cwd) catch return error.RecoveryRequired;
        if (left_behind) {
            expectSuccess(alloc, cwd, &.{ "merge", "--abort" }) catch return error.RecoveryRequired;
            if (try hasMergeHead(alloc, cwd)) return error.RecoveryRequired;
            const head_after = try branchTip(alloc, cwd, "HEAD");
            defer alloc.free(head_after);
            if (!std.mem.eql(u8, head_before, head_after)) return error.RecoveryRequired;
            const status_after = try run(alloc, cwd, &.{ "status", "--porcelain" });
            defer alloc.free(status_after);
            if (!std.mem.eql(u8, status_before, status_after)) return error.RecoveryRequired;
        }
        return error.GitFailed;
    }
    return branchTip(alloc, cwd, "HEAD");
}

pub fn diffNameOnly(alloc: Allocator, cwd: []const u8, base: []const u8, reference: []const u8) ![]u8 {
    const range = try std.fmt.allocPrint(alloc, "{s}...{s}", .{ base, reference });
    defer alloc.free(range);
    return run(alloc, cwd, &.{ "diff", "--name-only", range });
}

pub const DirtyEntry = struct {
    path: []u8,
    unmerged: bool,
};

pub const BaseError = error{ BaseUnmerged, BaseDetached, BaseOffBranch };

pub fn freeDirtyEntries(alloc: Allocator, entries: []DirtyEntry) void {
    for (entries) |entry| alloc.free(entry.path);
    alloc.free(entries);
}

fn unmergedCode(code: []const u8) bool {
    for ([_][]const u8{ "DD", "AU", "UD", "UA", "DU", "AA", "UU" }) |unmerged| {
        if (std.mem.eql(u8, code, unmerged)) return true;
    }
    return false;
}

fn underTowerRoot(path: []const u8) bool {
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, paths.tower_root)) return true;
    }
    return false;
}

pub fn parseDirtyEntries(alloc: Allocator, porcelain: []const u8) ![]DirtyEntry {
    var entries: std.ArrayList(DirtyEntry) = .empty;
    errdefer {
        for (entries.items) |entry| alloc.free(entry.path);
        entries.deinit(alloc);
    }
    var records = std.mem.splitScalar(u8, porcelain, 0);
    while (records.next()) |record| {
        if (record.len < 4) continue;
        const path = std.mem.trimEnd(u8, record[3..], "/");
        if (path.len == 0 or underTowerRoot(path)) continue;
        const owned = try alloc.dupe(u8, path);
        errdefer alloc.free(owned);
        try entries.append(alloc, .{ .path = owned, .unmerged = unmergedCode(record[0..2]) });
    }
    return entries.toOwnedSlice(alloc);
}

pub fn baseDirtyEntries(alloc: Allocator, cwd: []const u8) ![]DirtyEntry {
    const porcelain = try run(alloc, cwd, &.{ "status", "--porcelain", "-z", "--no-renames", "--untracked-files=normal" });
    defer alloc.free(porcelain);
    return parseDirtyEntries(alloc, porcelain);
}

fn runWithIndex(alloc: Allocator, cwd: []const u8, index_file: []const u8, args: []const []const u8) ![]u8 {
    var environment = try io_mod.cloneEnvironMap(alloc);
    defer environment.deinit();
    try environment.put("GIT_INDEX_FILE", index_file);
    try environment.put("GIT_LITERAL_PATHSPECS", "1");
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    try argv.append(alloc, "git");
    try argv.appendSlice(alloc, args);
    const result = try std.process.run(alloc, io_mod.getIo(), .{
        .argv = argv.items,
        .cwd = .{ .path = cwd },
        .environ_map = &environment,
    });
    defer alloc.free(result.stderr);
    const code: ?u8 = switch (result.term) {
        .exited => |exit_code| exit_code,
        else => null,
    };
    if (code != 0) {
        alloc.free(result.stdout);
        return error.GitFailed;
    }
    const trimmed = std.mem.trimEnd(u8, result.stdout, " \t\r\n");
    const owned = try alloc.dupe(u8, trimmed);
    alloc.free(result.stdout);
    return owned;
}

pub fn snapshotBaseWip(alloc: Allocator, root: []const u8, base: []const u8, changed: []const []const u8, message: []const u8) !?[]u8 {
    if (changed.len == 0) return null;
    const base_tip = try run(alloc, root, &.{ "rev-parse", base });
    defer alloc.free(base_tip);
    const absolute_root = try absolutePath(alloc, root);
    defer alloc.free(absolute_root);
    const index_file = try std.fmt.allocPrint(alloc, "{s}/.git/tower-wip.index", .{absolute_root});
    defer alloc.free(index_file);
    const read_tree = try runWithIndex(alloc, root, index_file, &.{ "read-tree", base_tip });
    alloc.free(read_tree);
    var start: usize = 0;
    while (start < changed.len) : (start += add_paths_chunk) {
        const end = @min(start + add_paths_chunk, changed.len);
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(alloc);
        try argv.appendSlice(alloc, &.{ "add", "-A", "--" });
        try argv.appendSlice(alloc, changed[start..end]);
        const added = try runWithIndex(alloc, root, index_file, argv.items);
        alloc.free(added);
    }
    const tree = try runWithIndex(alloc, root, index_file, &.{"write-tree"});
    defer alloc.free(tree);
    const base_tree_ref = try std.fmt.allocPrint(alloc, "{s}^{{tree}}", .{base_tip});
    defer alloc.free(base_tree_ref);
    const base_tree = try run(alloc, root, &.{ "rev-parse", base_tree_ref });
    defer alloc.free(base_tree);
    if (std.mem.eql(u8, tree, base_tree)) return null;
    var commit_argv: std.ArrayList([]const u8) = .empty;
    defer commit_argv.deinit(alloc);
    if (!try hasConfiguredIdentity(alloc, root)) try commit_argv.appendSlice(alloc, &fallback_identity);
    try commit_argv.appendSlice(alloc, &.{ "commit-tree", tree, "-p", base_tip, "-m", message });
    return try run(alloc, root, commit_argv.items);
}

pub fn addWorktreeForMission(alloc: Allocator, root: []const u8, path: []const u8, branch: []const u8, base: []const u8, owned: bool) !?[]u8 {
    if (try branchExists(alloc, root, branch)) {
        if (!owned) return error.UnownedBranch;
        try worktreeAdd(alloc, root, path, branch);
        return null;
    }
    const entries = try baseDirtyEntries(alloc, root);
    defer freeDirtyEntries(alloc, entries);
    var changed: std.ArrayList([]const u8) = .empty;
    defer changed.deinit(alloc);
    for (entries) |entry| {
        if (entry.unmerged) return error.BaseUnmerged;
        try changed.append(alloc, entry.path);
    }
    if (changed.items.len > 0) {
        const checkout = currentBranch(alloc, root) catch |err| switch (err) {
            error.DetachedHead => return error.BaseDetached,
            else => return err,
        };
        defer alloc.free(checkout);
        if (!std.mem.eql(u8, checkout, base)) return error.BaseOffBranch;
    }
    const spawn_base = try snapshotBaseWip(alloc, root, base, changed.items, "tower: snapshot of uncommitted base checkout changes");
    errdefer if (spawn_base) |sha| alloc.free(sha);
    worktreeAddNewBranch(alloc, root, path, branch, spawn_base orelse base) catch |err| {
        if (try branchExists(alloc, root, branch)) return error.UnownedBranch;
        return err;
    };
    return spawn_base;
}

fn initRepo(alloc: Allocator, cwd: []const u8) !void {
    try expectSuccess(alloc, cwd, &.{"init"});
}

test "Tower dirty entries parse porcelain records, skip the tower root and flag unmerged paths" {
    const alloc = std.testing.allocator;
    const entries = try parseDirtyEntries(alloc, " M src/a.zig\x00?? notes.txt\x00UU src/b.zig\x00?? .tower/comms/state.json\x00");
    defer freeDirtyEntries(alloc, entries);
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    try std.testing.expectEqualStrings("src/a.zig", entries[0].path);
    try std.testing.expect(!entries[0].unmerged);
    try std.testing.expectEqualStrings("src/b.zig", entries[2].path);
    try std.testing.expect(entries[2].unmerged);
}

test "Tower base snapshot commits the checkout's uncommitted changes and the mission branch starts from them" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(cwd);
    try initRepo(alloc, cwd);
    try tmp.dir.writeFile(io_mod.getIo(), .{ .sub_path = "base.txt", .data = "base\n" });
    try commitPaths(alloc, cwd, &.{"base.txt"}, "base");
    const base_branch = try currentBranch(alloc, cwd);
    defer alloc.free(base_branch);
    try tmp.dir.writeFile(io_mod.getIo(), .{ .sub_path = "base.txt", .data = "wip\n" });

    const entries = try baseDirtyEntries(alloc, cwd);
    defer freeDirtyEntries(alloc, entries);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    const changed = [_][]const u8{entries[0].path};
    const spawn_base = (try snapshotBaseWip(alloc, cwd, base_branch, &changed, "wip snapshot")).?;
    defer alloc.free(spawn_base);

    const still_dirty = try baseDirtyEntries(alloc, cwd);
    defer freeDirtyEntries(alloc, still_dirty);
    try std.testing.expectEqual(@as(usize, 1), still_dirty.len);

    const worktree = try std.fmt.allocPrint(alloc, "{s}/wt", .{cwd});
    defer alloc.free(worktree);
    try worktreeAddNewBranch(alloc, cwd, worktree, "tower/m1", spawn_base);
    const branch_text = try run(alloc, cwd, &.{ "show", "tower/m1:base.txt" });
    defer alloc.free(branch_text);
    try std.testing.expectEqualStrings("wip", branch_text);
}

test "Tower commits and base snapshots use the identity git is configured with" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(cwd);
    try initRepo(alloc, cwd);
    try expectSuccess(alloc, cwd, &.{ "config", "user.name", "Repo Author" });
    try expectSuccess(alloc, cwd, &.{ "config", "user.email", "author@example.com" });
    try std.testing.expect(try hasConfiguredIdentity(alloc, cwd));
    try tmp.dir.writeFile(io_mod.getIo(), .{ .sub_path = "base.txt", .data = "base\n" });
    try commitPaths(alloc, cwd, &.{"base.txt"}, "base");
    const base_branch = try currentBranch(alloc, cwd);
    defer alloc.free(base_branch);
    const committed = try run(alloc, cwd, &.{ "log", "-1", "--format=%an <%ae>" });
    defer alloc.free(committed);
    try std.testing.expectEqualStrings("Repo Author <author@example.com>", committed);

    try tmp.dir.writeFile(io_mod.getIo(), .{ .sub_path = "base.txt", .data = "wip\n" });
    const changed = [_][]const u8{"base.txt"};
    const snapshot = (try snapshotBaseWip(alloc, cwd, base_branch, &changed, "wip snapshot")).?;
    defer alloc.free(snapshot);
    const snapshot_author = try run(alloc, cwd, &.{ "log", "-1", "--format=%an <%ae>", snapshot });
    defer alloc.free(snapshot_author);
    try std.testing.expectEqualStrings("Repo Author <author@example.com>", snapshot_author);
}

test "Tower fallback identity names no person" {
    try std.testing.expectEqualStrings("user.name=fx", fallback_identity[1]);
    try std.testing.expectEqualStrings("user.email=fx@localhost", fallback_identity[3]);
}

test "Tower git reports a missing branch as false without failing" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(cwd);
    try initRepo(alloc, cwd);
    const exists = try branchExists(alloc, cwd, "no-such-branch");
    try std.testing.expect(!exists);
}

test "Tower git worktree, commit and no-ff merge round trip" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(cwd);
    try initRepo(alloc, cwd);
    try tmp.dir.writeFile(io_mod.getIo(), .{ .sub_path = "base.txt", .data = "base\n" });
    try commitPaths(alloc, cwd, &.{"base.txt"}, "base");
    const base_branch = try currentBranch(alloc, cwd);
    defer alloc.free(base_branch);

    const worktree = try std.fmt.allocPrint(alloc, "{s}/wt", .{cwd});
    defer alloc.free(worktree);
    try worktreeAddNewBranch(alloc, cwd, worktree, "tower/m1", base_branch);
    try std.testing.expect(try branchExists(alloc, cwd, "tower/m1"));
    const dirty_before = try isWorktreeDirty(alloc, worktree);
    try std.testing.expect(!dirty_before);

    try tmp.dir.writeFile(io_mod.getIo(), .{ .sub_path = "wt/feature.txt", .data = "feature\n" });
    const dirty_after = try isWorktreeDirty(alloc, worktree);
    try std.testing.expect(dirty_after);
    try commitPaths(alloc, worktree, &.{"feature.txt"}, "feature");
    try std.testing.expect(try isAncestor(alloc, cwd, base_branch, "tower/m1"));

    const names = try diffNameOnly(alloc, cwd, base_branch, "tower/m1");
    defer alloc.free(names);
    try std.testing.expectEqualStrings("feature.txt", names);
    const merged = try mergeNoFf(alloc, cwd, "tower/m1", "merge m1");
    defer alloc.free(merged);
}

test "Tower git refuses a merge while MERGE_HEAD exists" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(cwd);
    try initRepo(alloc, cwd);
    try tmp.dir.writeFile(io_mod.getIo(), .{ .sub_path = "base.txt", .data = "base\n" });
    try commitPaths(alloc, cwd, &.{"base.txt"}, "base");
    const tip = try branchTip(alloc, cwd, "HEAD");
    defer alloc.free(tip);
    const merge_head = try std.fmt.allocPrint(alloc, "{s}\n", .{tip});
    defer alloc.free(merge_head);
    try tmp.dir.writeFile(io_mod.getIo(), .{ .sub_path = ".git/MERGE_HEAD", .data = merge_head });
    try std.testing.expectError(error.MergeHeadExists, mergeNoFf(alloc, cwd, "HEAD", null));
}

test "Tower worktree refuses an existing branch no mission owns and attaches one a mission owns" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(cwd);
    try initRepo(alloc, cwd);
    try tmp.dir.writeFile(io_mod.getIo(), .{ .sub_path = "base.txt", .data = "base\n" });
    try commitPaths(alloc, cwd, &.{"base.txt"}, "base");
    try expectSuccess(alloc, cwd, &.{ "branch", "feat/parser" });
    const worktree = try std.fmt.allocPrint(alloc, "{s}/.tower/worktrees/wt-1", .{cwd});
    defer alloc.free(worktree);
    try std.testing.expectError(error.UnownedBranch, addWorktreeForMission(alloc, cwd, worktree, "feat/parser", "main", false));
    const spawn_base = try addWorktreeForMission(alloc, cwd, worktree, "feat/parser", "main", true);
    try std.testing.expect(spawn_base == null);
    try std.testing.expect(!(try isWorktreeDirty(alloc, worktree)));
}
