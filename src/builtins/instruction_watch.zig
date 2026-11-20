const std = @import("std");
const io_mod = @import("../core/shared/io.zig");
const model_context_encoding = @import("../core/shared/model_context_encoding.zig");
const pathing = @import("../core/workspace/pathing.zig");

const Allocator = std.mem.Allocator;

pub const max_watched_files = 256;
pub const max_named_files = 8;
const max_path_bytes = 1024;
const max_hashed_bytes = 16 * 1024 * 1024;
const hash_chunk_bytes = 16 * 1024;
const missing_hash: u64 = 0;

const Fingerprint = struct {
    size: u64,
    mtime: i96,
    hash: u64,
};

const Entry = struct {
    path_buf: [max_path_bytes]u8,
    path_len: usize,
    baseline: u64,
    seen_size: u64,
    seen_mtime: i96,
    current: u64,

    fn path(self: *const Entry) []const u8 {
        return self.path_buf[0..self.path_len];
    }
};

var mutex: std.Io.Mutex = .init;
var entries: [max_watched_files]Entry = undefined;
var entry_count: usize = 0;

fn nonMissing(hash: u64) u64 {
    return if (hash == missing_hash) 1 else hash;
}

fn statHash(size: u64, mtime: i96) u64 {
    const wide_mtime: i128 = mtime;
    var hasher = std.hash.Wyhash.init(1);
    hasher.update(std.mem.asBytes(&size));
    hasher.update(std.mem.asBytes(&wide_mtime));
    return nonMissing(hasher.final());
}

fn fingerprint(path: []const u8) Fingerprint {
    const io = io_mod.getIo();
    const missing: Fingerprint = .{ .size = 0, .mtime = 0, .hash = missing_hash };
    var file = std.Io.Dir.cwd().openFile(io, path, .{ .allow_directory = false }) catch return missing;
    defer file.close(io);
    const stat = file.stat(io) catch return missing;
    const mtime = stat.mtime.nanoseconds;
    var hasher = std.hash.Wyhash.init(0);
    var chunk: [hash_chunk_bytes]u8 = undefined;
    var offset: u64 = 0;
    while (offset < max_hashed_bytes) {
        const read = file.readPositionalAll(io, &chunk, offset) catch
            return .{ .size = stat.size, .mtime = mtime, .hash = statHash(stat.size, mtime) };
        hasher.update(chunk[0..read]);
        offset += read;
        if (read < chunk.len) break;
    }
    return .{ .size = stat.size, .mtime = mtime, .hash = nonMissing(hasher.final()) };
}

fn findLocked(path: []const u8) ?*Entry {
    for (entries[0..entry_count]) |*entry| {
        if (std.mem.eql(u8, entry.path(), path)) return entry;
    }
    return null;
}

pub fn watch(path: []const u8) void {
    if (path.len == 0 or path.len > max_path_bytes or !std.Io.Dir.path.isAbsolute(path)) return;
    const io = io_mod.getIo();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    if (findLocked(path) != null or entry_count == max_watched_files) return;
    const seen = fingerprint(path);
    const entry = &entries[entry_count];
    @memcpy(entry.path_buf[0..path.len], path);
    entry.path_len = path.len;
    entry.baseline = seen.hash;
    entry.seen_size = seen.size;
    entry.seen_mtime = seen.mtime;
    entry.current = seen.hash;
    entry_count += 1;
}

pub fn watchAll(paths: []const []const u8) void {
    for (paths) |path| watch(path);
}

fn applies(workspace_root: []const u8, path: []const u8) bool {
    if (pathing.pathInside(workspace_root, path)) return true;
    const parent = std.Io.Dir.path.dirname(path) orelse return false;
    return pathing.pathInside(parent, workspace_root);
}

fn refreshLocked(entry: *Entry) void {
    const io = io_mod.getIo();
    const stat = std.Io.Dir.cwd().statFile(io, entry.path(), .{}) catch {
        entry.seen_size = 0;
        entry.seen_mtime = 0;
        entry.current = missing_hash;
        return;
    };
    if (stat.size == entry.seen_size and stat.mtime.nanoseconds == entry.seen_mtime and entry.current != missing_hash) return;
    const seen = fingerprint(entry.path());
    entry.seen_size = seen.size;
    entry.seen_mtime = seen.mtime;
    entry.current = seen.hash;
}

pub fn changedNote(arena: Allocator, workspace_root: []const u8) Allocator.Error!?[]const u8 {
    if (!std.Io.Dir.path.isAbsolute(workspace_root)) return null;
    var names: std.Io.Writer.Allocating = .init(arena);
    defer names.deinit();
    var revision = std.hash.Wyhash.init(0);
    var changed: usize = 0;
    {
        const io = io_mod.getIo();
        mutex.lockUncancelable(io);
        defer mutex.unlock(io);
        for (entries[0..entry_count]) |*entry| {
            if (!applies(workspace_root, entry.path())) continue;
            refreshLocked(entry);
            if (entry.current == entry.baseline) continue;
            changed += 1;
            revision.update(entry.path());
            revision.update(std.mem.asBytes(&entry.current));
            if (changed > max_named_files) continue;
            if (changed > 1) names.writer.writeAll(", ") catch return error.OutOfMemory;
            names.writer.writeByte('`') catch return error.OutOfMemory;
            model_context_encoding.writeScalar(&names.writer, pathing.workspaceRelative(workspace_root, entry.path())) catch return error.OutOfMemory;
            names.writer.writeByte('`') catch return error.OutOfMemory;
        }
    }
    if (changed == 0) return null;
    if (changed > max_named_files) names.writer.print(" and {d} more", .{changed - max_named_files}) catch return error.OutOfMemory;
    return try std.fmt.allocPrint(
        arena,
        "Runtime context: project instruction files changed on disk after fx read them: {s} (revision {x:0>16}). The text now on disk applies from here on; read each changed file again before relying on its rules.",
        .{ names.written(), revision.final() },
    );
}

pub fn resetForTest() void {
    const io = io_mod.getIo();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    entry_count = 0;
}

fn writeFixture(dir: std.Io.Dir, name: []const u8, content: []const u8) !void {
    if (std.Io.Dir.path.dirname(name)) |parent| try dir.createDirPath(io_mod.getIo(), parent);
    try dir.writeFile(io_mod.getIo(), .{ .sub_path = name, .data = content });
}

test "an instruction file that is unchanged since fx read it adds no note" {
    resetForTest();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try writeFixture(tmp.dir, "work/AGENTS.md", "Use tabs.\n");
    const root = try io_mod.dirRealpathAlloc(arena, tmp.dir, "work");
    const source = try std.Io.Dir.path.join(arena, &.{ root, "AGENTS.md" });

    watch(source);
    try std.testing.expect(try changedNote(arena, root) == null);
    watch(source);
    try std.testing.expectEqual(@as(usize, 1), entry_count);
}

test "an instruction file edited during the session is named once per revision and the new text is said to apply" {
    resetForTest();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try writeFixture(tmp.dir, "work/AGENTS.md", "Use tabs.\n");
    try writeFixture(tmp.dir, "work/src/AGENTS.md", "Scoped rule.\n");
    const root = try io_mod.dirRealpathAlloc(arena, tmp.dir, "work");
    const project = try std.Io.Dir.path.join(arena, &.{ root, "AGENTS.md" });
    const scoped = try std.Io.Dir.path.join(arena, &.{ root, "src", "AGENTS.md" });
    watchAll(&.{ project, scoped });

    try writeFixture(tmp.dir, "work/AGENTS.md", "Use two spaces, never tabs.\n");
    const first = (try changedNote(arena, root)).?;
    try std.testing.expect(std.mem.startsWith(u8, first, "Runtime context: project instruction files changed on disk after fx read them: `AGENTS.md` (revision "));
    try std.testing.expect(std.mem.endsWith(u8, first, "). The text now on disk applies from here on; read each changed file again before relying on its rules."));
    try std.testing.expect(std.mem.find(u8, first, "src") == null);
    try std.testing.expectEqualStrings(first, (try changedNote(arena, root)).?);

    try writeFixture(tmp.dir, "work/src/AGENTS.md", "Scoped rule, second edition.\n");
    const second = (try changedNote(arena, root)).?;
    try std.testing.expect(std.mem.find(u8, second, "`AGENTS.md`, `src") != null);
    try std.testing.expect(!std.mem.eql(u8, first, second));
}

test "a deleted instruction file counts as changed and a file restored to its first text does not" {
    resetForTest();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try writeFixture(tmp.dir, "work/AGENTS.md", "Use tabs.\n");
    const root = try io_mod.dirRealpathAlloc(arena, tmp.dir, "work");
    const source = try std.Io.Dir.path.join(arena, &.{ root, "AGENTS.md" });
    watch(source);

    try tmp.dir.deleteFile(io_mod.getIo(), "work/AGENTS.md");
    try std.testing.expect(try changedNote(arena, root) != null);
    try writeFixture(tmp.dir, "work/AGENTS.md", "Use tabs.\n");
    try std.testing.expect(try changedNote(arena, root) == null);
}

test "a change in another workspace is not reported, and a change in a parent folder's instruction file is" {
    resetForTest();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try writeFixture(tmp.dir, "home/AGENTS.md", "Parent rule.\n");
    try writeFixture(tmp.dir, "home/work/AGENTS.md", "Use tabs.\n");
    try writeFixture(tmp.dir, "home/other/AGENTS.md", "Other project.\n");
    const work = try io_mod.dirRealpathAlloc(arena, tmp.dir, "home/work");
    const other = try io_mod.dirRealpathAlloc(arena, tmp.dir, "home/other");
    const home = try io_mod.dirRealpathAlloc(arena, tmp.dir, "home");
    watchAll(&.{
        try std.Io.Dir.path.join(arena, &.{ home, "AGENTS.md" }),
        try std.Io.Dir.path.join(arena, &.{ work, "AGENTS.md" }),
        try std.Io.Dir.path.join(arena, &.{ other, "AGENTS.md" }),
    });

    try writeFixture(tmp.dir, "home/other/AGENTS.md", "Other project, changed.\n");
    try std.testing.expect(try changedNote(arena, work) == null);
    try std.testing.expect(try changedNote(arena, other) != null);

    try writeFixture(tmp.dir, "home/AGENTS.md", "Parent rule, changed.\n");
    const note = (try changedNote(arena, work)).?;
    try std.testing.expect(std.mem.find(u8, note, "AGENTS.md`") != null);
}

test "relative and overlong paths are not watched" {
    resetForTest();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    watch("AGENTS.md");
    watch("");
    const long = try arena.alloc(u8, max_path_bytes + 1);
    @memset(long, 'a');
    long[0] = std.Io.Dir.path.sep;
    watch(long);
    try std.testing.expectEqual(@as(usize, 0), entry_count);
    try std.testing.expect(try changedNote(arena, "relative") == null);
}
