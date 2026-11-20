const std = @import("std");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;

const metadata_file_bytes: usize = 64 * 1024;
const packed_refs_file_bytes: usize = 4 * 1024 * 1024;

pub fn read(arena: Allocator, workspace_root: []const u8) Allocator.Error!?[]const u8 {
    if (workspace_root.len == 0 or !std.Io.Dir.path.isAbsolute(workspace_root)) return null;
    const git_dir = (try resolveGitDir(arena, workspace_root)) orelse return null;
    const head = readSmallFile(arena, try std.Io.Dir.path.join(arena, &.{ git_dir, "HEAD" }), metadata_file_bytes) orelse return null;
    const trimmed = std.mem.trim(u8, head, " \t\r\n");
    const prefix = "ref:";
    if (!std.mem.startsWith(u8, trimmed, prefix)) return objectName(trimmed);
    const ref = std.mem.trim(u8, trimmed[prefix.len..], " \t\r\n");
    if (ref.len == 0 or std.mem.find(u8, ref, "..") != null) return null;
    const common_dir = try resolveCommonGitDir(arena, git_dir);
    for ([_][]const u8{ git_dir, common_dir }) |dir| {
        const loose = readSmallFile(arena, try std.Io.Dir.path.join(arena, &.{ dir, ref }), metadata_file_bytes) orelse continue;
        if (objectName(std.mem.trim(u8, loose, " \t\r\n"))) |name| return name;
    }
    const packed_refs = readSmallFile(arena, try std.Io.Dir.path.join(arena, &.{ common_dir, "packed-refs" }), packed_refs_file_bytes) orelse return null;
    return packedObjectName(packed_refs, ref);
}

fn objectName(text: []const u8) ?[]const u8 {
    if (text.len != 40 and text.len != 64) return null;
    for (text) |byte| {
        if (!std.ascii.isHex(byte)) return null;
    }
    return text;
}

fn packedObjectName(packed_refs: []const u8, ref: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, packed_refs, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#' or trimmed[0] == '^') continue;
        const space = std.mem.findScalar(u8, trimmed, ' ') orelse continue;
        if (!std.mem.eql(u8, trimmed[space + 1 ..], ref)) continue;
        return objectName(trimmed[0..space]);
    }
    return null;
}

fn resolveGitDir(arena: Allocator, workspace_root: []const u8) Allocator.Error!?[]const u8 {
    const dot_git = try std.Io.Dir.path.join(arena, &.{ workspace_root, ".git" });
    const stat = std.Io.Dir.cwd().statFile(io_mod.getIo(), dot_git, .{ .follow_symlinks = false }) catch return null;
    if (stat.kind == .directory) return dot_git;
    if (stat.kind != .file) return null;
    const content = readSmallFile(arena, dot_git, metadata_file_bytes) orelse return null;
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    const prefix = "gitdir:";
    if (!std.mem.startsWith(u8, trimmed, prefix)) return null;
    const raw = std.mem.trim(u8, trimmed[prefix.len..], " \t\r\n");
    if (raw.len == 0) return null;
    if (std.Io.Dir.path.isAbsolute(raw)) return try arena.dupe(u8, raw);
    return try std.Io.Dir.path.join(arena, &.{ workspace_root, raw });
}

fn resolveCommonGitDir(arena: Allocator, git_dir: []const u8) Allocator.Error![]const u8 {
    const content = readSmallFile(arena, try std.Io.Dir.path.join(arena, &.{ git_dir, "commondir" }), metadata_file_bytes) orelse return git_dir;
    const raw = std.mem.trim(u8, content, " \t\r\n");
    if (raw.len == 0) return git_dir;
    if (std.Io.Dir.path.isAbsolute(raw)) return try arena.dupe(u8, raw);
    return try std.Io.Dir.path.join(arena, &.{ git_dir, raw });
}

fn readSmallFile(arena: Allocator, path: []const u8, max_bytes: usize) ?[]const u8 {
    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{}) catch return null;
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(arena, &file, max_bytes) catch null;
}

fn writeTestFile(dir: std.Io.Dir, name: []const u8, content: []const u8) !void {
    if (std.Io.Dir.path.dirname(name)) |parent| {
        try dir.createDirPath(io_mod.getIo(), parent);
    }
    var file = try dir.createFile(io_mod.getIo(), name, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), content);
}

const test_commit = "0123456789abcdef0123456789abcdef01234567";
const other_commit = "89abcdef0123456789abcdef0123456789abcdef";

test "git head reads a branch ref, a packed ref and a detached commit without starting a process" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try writeTestFile(tmp.dir, "loose/.git/HEAD", "ref: refs/heads/main\n");
    try writeTestFile(tmp.dir, "loose/.git/refs/heads/main", test_commit ++ "\n");
    try writeTestFile(tmp.dir, "packed/.git/HEAD", "ref: refs/heads/topic\n");
    try writeTestFile(tmp.dir, "packed/.git/packed-refs", "# pack-refs with: peeled fully-peeled sorted\n" ++ other_commit ++ " refs/heads/main\n" ++ test_commit ++ " refs/heads/topic\n");
    try writeTestFile(tmp.dir, "detached/.git/HEAD", other_commit ++ "\n");

    const loose = try io_mod.dirRealpathAlloc(arena, tmp.dir, "loose");
    try std.testing.expectEqualStrings(test_commit, (try read(arena, loose)).?);
    const packed_root = try io_mod.dirRealpathAlloc(arena, tmp.dir, "packed");
    try std.testing.expectEqualStrings(test_commit, (try read(arena, packed_root)).?);
    const detached = try io_mod.dirRealpathAlloc(arena, tmp.dir, "detached");
    try std.testing.expectEqualStrings(other_commit, (try read(arena, detached)).?);
}

test "git head is absent outside a repository, for an unborn branch and for a malformed HEAD" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try writeTestFile(tmp.dir, "plain/readme.txt", "no repository\n");
    try writeTestFile(tmp.dir, "unborn/.git/HEAD", "ref: refs/heads/main\n");
    try writeTestFile(tmp.dir, "malformed/.git/HEAD", "not a commit\n");
    try writeTestFile(tmp.dir, "escaping/.git/HEAD", "ref: ../../outside\n");

    for ([_][]const u8{ "plain", "unborn", "malformed", "escaping" }) |name| {
        const root = try io_mod.dirRealpathAlloc(arena, tmp.dir, name);
        try std.testing.expect(try read(arena, root) == null);
    }
    try std.testing.expect(try read(arena, "") == null);
    try std.testing.expect(try read(arena, "relative/path") == null);
}

test "git head follows a linked worktree to the shared refs" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try writeTestFile(tmp.dir, "main/.git/refs/heads/feature", test_commit ++ "\n");
    try writeTestFile(tmp.dir, "main/.git/worktrees/linked/HEAD", "ref: refs/heads/feature\n");
    try writeTestFile(tmp.dir, "main/.git/worktrees/linked/commondir", "../..\n");
    try writeTestFile(tmp.dir, "linked/.git", "gitdir: ../main/.git/worktrees/linked\n");

    const linked = try io_mod.dirRealpathAlloc(arena, tmp.dir, "linked");
    try std.testing.expectEqualStrings(test_commit, (try read(arena, linked)).?);
}
