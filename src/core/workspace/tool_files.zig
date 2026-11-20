const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const file_index = @import("file_index.zig");
const indexer = @import("../indexer/indexer.zig");
const pathing = @import("pathing.zig");

const Allocator = std.mem.Allocator;

pub const default_candidate_cap: usize = 100_000;
const max_relative_path_bytes: usize = 2048;
pub const default_skipped_names: []const []const u8 = &indexer.default_skipped_names;

pub const Options = struct {
    candidate_cap: usize = default_candidate_cap,
    skipped_names: []const []const u8 = default_skipped_names,
    include_hidden: bool = false,
    include_hidden_in_repository: bool = false,
    include_ignored: bool = false,
};

pub const Listing = struct {
    files: []const []const u8,
    candidate_cap: usize,
    incomplete: bool,
    cap_reached: bool,
    skipped_overlong: usize,
};

pub const Error = Allocator.Error || error{FileNotFound};

pub fn list(alloc: Allocator, arena: Allocator, workspace_root: []const u8, absolute_root: []const u8, options: Options) Error!Listing {
    if (!options.include_ignored) {
        if (relativeInside(workspace_root, absolute_root)) |subtree| {
            if (try listFromSnapshot(alloc, arena, workspace_root, subtree, options)) |listing| return listing;
        }
    }
    var result = indexer.scan(alloc, absolute_root, .{
        .candidate_cap = options.candidate_cap,
        .max_path_bytes = max_relative_path_bytes,
        .skipped_names = options.skipped_names,
        .respect_ignore_files = !options.include_ignored,
    }, null) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.RootUnavailable => return error.FileNotFound,
        error.Canceled => unreachable,
    };
    defer result.deinit();
    debug_trace.logf("core", "tool files scanned entries={d} incomplete={} cap_reached={}", .{ result.tree.entries.len, result.tree.incomplete, result.tree.cap_reached });
    return collect(arena, &result.tree, "", options);
}

fn relativeInside(workspace_root: []const u8, absolute_root: []const u8) ?[]const u8 {
    if (workspace_root.len == 0 or !pathing.pathInside(workspace_root, absolute_root)) return null;
    return std.mem.trimStart(u8, absolute_root[workspace_root.len..], "/");
}

fn subtreeFromSnapshot(tree: *const indexer.Tree, subtree: []const u8) bool {
    if (subtree.len == 0) return true;
    for (tree.folders) |folder| {
        if (std.mem.eql(u8, folder.rel, subtree)) return !folder.boundary and !folder.excluded;
    }
    return false;
}

fn capAllowsReuse(tree: *const indexer.Tree, subtree: []const u8, candidate_cap: usize) bool {
    var files: usize = 0;
    for (tree.entries) |entry| files += @intFromBool(entry.kind == .file);
    if (files > candidate_cap) return false;
    return !tree.cap_reached or (subtree.len == 0 and files == candidate_cap);
}

fn listFromSnapshot(alloc: Allocator, arena: Allocator, workspace_root: []const u8, subtree: []const u8, options: Options) Allocator.Error!?Listing {
    const roots = [_][]const u8{workspace_root};
    const path = (try file_index.snapshotPath(arena, &roots)) orelse return null;
    var snapshot = (try indexer.loadSnapshot(alloc, path, &roots)) orelse return null;
    defer snapshot.deinit();
    const tree = &snapshot.trees[0];
    if (!capAllowsReuse(tree, subtree, options.candidate_cap)) return null;
    if (!subtreeFromSnapshot(tree, subtree)) return null;
    if (!indexer.isCurrent(tree, workspace_root, options.skipped_names, if (subtree.len == 0) null else subtree)) return null;
    debug_trace.logf("core", "tool files reused snapshot entries={d} subtree_bytes={d}", .{ tree.entries.len, subtree.len });
    return try collect(arena, tree, subtree, options);
}

fn subtreePath(entry: indexer.Entry, subtree: []const u8) ?[]const u8 {
    if (entry.kind != .file) return null;
    if (subtree.len == 0) return entry.path;
    if (entry.path.len <= subtree.len + 1 or !std.mem.startsWith(u8, entry.path, subtree) or entry.path[subtree.len] != '/') return null;
    return entry.path[subtree.len + 1 ..];
}

fn collect(arena: Allocator, tree: *const indexer.Tree, subtree: []const u8, options: Options) Allocator.Error!Listing {
    const keep_hidden = options.include_hidden or options.include_ignored or (options.include_hidden_in_repository and tree.repository);

    var upper: usize = 0;
    for (tree.entries) |entry| upper += @intFromBool(subtreePath(entry, subtree) != null);
    const files = try arena.alloc([]const u8, upper);
    var count: usize = 0;
    for (tree.entries) |entry| {
        const path = subtreePath(entry, subtree) orelse continue;
        if (!keep_hidden and pathContainsHiddenDirectoryComponent(path)) continue;
        files[count] = try arena.dupe(u8, path);
        count += 1;
    }
    return .{
        .files = files[0..count],
        .candidate_cap = options.candidate_cap,
        .incomplete = tree.incomplete or tree.cap_reached,
        .cap_reached = tree.cap_reached,
        .skipped_overlong = tree.skipped_overlong,
    };
}

pub const Completeness = struct {
    incomplete: bool = false,
    cap_reached: bool = false,
    candidate_cap: usize = default_candidate_cap,
    skipped_overlong: usize = 0,

    pub fn of(listing: Listing) Completeness {
        return .{
            .incomplete = listing.incomplete,
            .cap_reached = listing.cap_reached,
            .candidate_cap = listing.candidate_cap,
            .skipped_overlong = listing.skipped_overlong,
        };
    }

    pub fn writeNotes(self: Completeness, writer: *std.Io.Writer) error{OutOfMemory}!void {
        if (self.cap_reached) {
            writer.print("... candidate list may be incomplete; candidate cap {d} reached before all files were discovered\n", .{self.candidate_cap}) catch return error.OutOfMemory;
        } else if (self.incomplete) {
            writer.writeAll("... candidate list may be incomplete; some folders or git files could not be read\n") catch return error.OutOfMemory;
        }
        if (self.skipped_overlong > 0) {
            writer.print("... skipped {d} overlong candidate path{s}\n", .{ self.skipped_overlong, if (self.skipped_overlong == 1) "" else "s" }) catch return error.OutOfMemory;
        }
    }
};

pub fn pathContainsHiddenDirectoryComponent(path: []const u8) bool {
    var rest = path;
    while (std.mem.findScalar(u8, rest, '/')) |slash| {
        const component = rest[0..slash];
        if (component.len > 1 and component[0] == '.') return true;
        rest = rest[slash + 1 ..];
    }
    return false;
}

test "hidden directory components exclude descendants but not hidden files" {
    try std.testing.expect(pathContainsHiddenDirectoryComponent(".github/workflows/ci.yml"));
    try std.testing.expect(pathContainsHiddenDirectoryComponent("src/.cache/item"));
    try std.testing.expect(!pathContainsHiddenDirectoryComponent(".gitignore"));
    try std.testing.expect(!pathContainsHiddenDirectoryComponent("src/.env"));
    try std.testing.expect(!pathContainsHiddenDirectoryComponent("./src/main.zig"));
}

test "listing sees a file created a moment earlier and honors hidden and custom names" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    for ([_][]const u8{ "root/a.txt", "root/.hidden/h.txt", "root/build/out.o", "root/vendor/v.txt", "root/sub/s.txt" }) |sub_path| {
        try tmp.dir.createDirPath(io, std.Io.Dir.path.dirname(sub_path).?);
        try tmp.dir.writeFile(io, .{ .sub_path = sub_path, .data = "x" });
    }
    const root = try @import("../shared/io.zig").dirRealpathAlloc(arena, tmp.dir, "root");

    const first = try list(std.testing.allocator, arena, root, root, .{});
    try std.testing.expectEqual(@as(usize, 3), first.files.len);
    try std.testing.expectEqualStrings("a.txt", first.files[0]);
    try std.testing.expectEqualStrings("sub/s.txt", first.files[1]);
    try std.testing.expectEqualStrings("vendor/v.txt", first.files[2]);

    try tmp.dir.writeFile(io, .{ .sub_path = "root/sub/new.txt", .data = "x" });
    const custom = try list(std.testing.allocator, arena, root, root, .{ .skipped_names = &.{"vendor"}, .include_hidden = true });
    const want = [_][]const u8{ ".hidden/h.txt", "a.txt", "build/out.o", "sub/new.txt", "sub/s.txt" };
    try std.testing.expectEqual(want.len, custom.files.len);
    for (want, custom.files) |expected, actual| try std.testing.expectEqualStrings(expected, actual);

    const sub = try list(std.testing.allocator, arena, root, try std.Io.Dir.path.join(arena, &.{ root, "sub" }), .{});
    try std.testing.expectEqual(@as(usize, 2), sub.files.len);
    try std.testing.expectEqualStrings("new.txt", sub.files[0]);

    try std.testing.expectError(error.FileNotFound, list(std.testing.allocator, arena, root, try std.Io.Dir.path.join(arena, &.{ root, "missing" }), .{}));
}

test "subfolder searches reuse the workspace tree only for ordinary folders" {
    const folders = [_]indexer.FolderStamp{
        .{ .rel = "", .inode = 1, .mtime_ns = 0, .ctime_ns = 0, .reusable = true },
        .{ .rel = "src", .inode = 2, .mtime_ns = 0, .ctime_ns = 0, .reusable = true },
        .{ .rel = "inner", .inode = 3, .mtime_ns = 0, .ctime_ns = 0, .reusable = true, .boundary = true },
        .{ .rel = "build", .inode = 4, .mtime_ns = 0, .ctime_ns = 0, .reusable = true, .excluded = true },
    };
    const tree: indexer.Tree = .{ .root = "/w", .root_inode = 1, .scan_started_ns = 0, .repository = true, .incomplete = false, .cap_reached = false, .skipped_overlong = 0, .skipped_names = &.{}, .entries = &.{}, .folders = &folders, .sources = &.{} };
    try std.testing.expect(subtreeFromSnapshot(&tree, ""));
    try std.testing.expect(subtreeFromSnapshot(&tree, "src"));
    try std.testing.expect(!subtreeFromSnapshot(&tree, "inner"));
    try std.testing.expect(!subtreeFromSnapshot(&tree, "build"));
    try std.testing.expect(!subtreeFromSnapshot(&tree, "vendor"));
    try std.testing.expectEqualStrings("src/core", relativeInside("/w", "/w/src/core").?);
    try std.testing.expectEqualStrings("", relativeInside("/w", "/w").?);
    try std.testing.expect(relativeInside("/w", "/workspace") == null);
    try std.testing.expect(relativeInside("/w", "/other") == null);
}

test "a tree cut at the cap answers only a whole-workspace search with the same cap" {
    const entries = [_]indexer.Entry{
        .{ .path = "src", .kind = .directory },
        .{ .path = "src/a.zig", .kind = .file },
        .{ .path = "src/b.zig", .kind = .file },
        .{ .path = "tools", .kind = .directory },
    };
    var tree: indexer.Tree = .{ .root = "/w", .root_inode = 1, .scan_started_ns = 0, .repository = true, .incomplete = false, .cap_reached = false, .skipped_overlong = 0, .skipped_names = &.{}, .entries = &entries, .folders = &.{}, .sources = &.{} };

    try std.testing.expect(capAllowsReuse(&tree, "", 2));
    try std.testing.expect(capAllowsReuse(&tree, "src", 2));
    try std.testing.expect(!capAllowsReuse(&tree, "", 1));

    tree.cap_reached = true;
    try std.testing.expect(capAllowsReuse(&tree, "", 2));
    try std.testing.expect(!capAllowsReuse(&tree, "", 3));
    try std.testing.expect(!capAllowsReuse(&tree, "src", 2));
    try std.testing.expect(!capAllowsReuse(&tree, "tools", 2));
}
