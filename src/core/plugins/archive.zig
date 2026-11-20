const std = @import("std");
const io_mod = @import("../shared/io.zig");
const manifest = @import("manifest.zig");

const Allocator = std.mem.Allocator;
const cwd = std.Io.Dir.cwd;

pub const max_extracted_bytes: u64 = 512 * 1024 * 1024;

pub const Error = error{
    PluginArchiveInvalid,
    PluginArchivePathTraversal,
    PluginArchiveTooLarge,
};

pub fn extractZipFile(arena: Allocator, zip_path: []const u8, dest_dir: []const u8) ![]const u8 {
    const io = io_mod.getIo();
    try cwd().createDirPath(io, dest_dir);
    var dest = try cwd().openDir(io, dest_dir, .{});
    defer dest.close(io);
    var file = try cwd().openFile(io, zip_path, .{});
    defer file.close(io);
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);

    var entries = std.zip.Iterator.init(&reader) catch return error.PluginArchiveInvalid;
    var name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var extracted_bytes: u64 = 0;
    while (entries.next() catch return error.PluginArchiveInvalid) |entry| {
        const name = entry.getFilename(&reader, &name_buffer, .{ .allow_backslashes = true }) catch |err| switch (err) {
            error.ZipBadFilename => return error.PluginArchivePathTraversal,
            else => return error.PluginArchiveInvalid,
        };
        if (escapesDestination(name)) return error.PluginArchivePathTraversal;
        extracted_bytes +|= entry.uncompressed_size;
        if (extracted_bytes > max_extracted_bytes) return error.PluginArchiveTooLarge;
        const name_len = name.len;
        entry.extract(&reader, .{ .allow_backslashes = true }, &name_buffer, dest) catch |err| switch (err) {
            error.ZipBadFilename => return error.PluginArchivePathTraversal,
            else => return error.PluginArchiveInvalid,
        };
        restoreFileMode(io, dest, &reader, entry, name_buffer[0..name_len]) catch {};
    }
    return detectPluginRoot(arena, dest_dir);
}

pub fn escapesDestination(entry_name: []const u8) bool {
    if (entry_name.len == 0 or entry_name[0] == '/' or entry_name[0] == '\\') return true;
    if (entry_name.len >= 2 and entry_name[1] == ':') return true;
    var parts = std.mem.tokenizeAny(u8, entry_name, "/\\");
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return true;
    }
    return false;
}

fn restoreFileMode(
    io: std.Io,
    dest: std.Io.Dir,
    reader: *std.Io.File.Reader,
    entry: std.zip.Iterator.Entry,
    name: []const u8,
) !void {
    if (comptime !std.Io.File.Permissions.has_executable_bit) return;
    if (name.len == 0 or name[name.len - 1] == '/') return;
    try reader.seekTo(entry.header_zip_offset);
    const header = try reader.interface.takeStruct(std.zip.CentralDirectoryFileHeader, .little);
    const permission_bits: u32 = (header.external_file_attributes >> 16) & 0o777;
    if (permission_bits == 0) return;
    var extracted = try dest.openFile(io, name, .{});
    defer extracted.close(io);
    try extracted.setPermissions(io, std.Io.File.Permissions.fromMode(@intCast(permission_bits)));
}

pub fn detectPluginRoot(arena: Allocator, dir: []const u8) ![]const u8 {
    const io = io_mod.getIo();
    if (try hasManifest(arena, io, dir)) return dir;
    var handle = cwd().openDir(io, dir, .{ .iterate = true }) catch return dir;
    defer handle.close(io);
    var only_child: ?[]const u8 = null;
    var child_dir_count: usize = 0;
    var children = handle.iterate();
    while (try children.next(io)) |child| {
        if (child.kind != .directory) continue;
        child_dir_count += 1;
        if (child_dir_count == 1) only_child = try arena.dupe(u8, child.name);
    }
    if (child_dir_count != 1) return dir;
    const child_path = try std.Io.Dir.path.join(arena, &.{ dir, only_child orelse return dir });
    return if (try hasManifest(arena, io, child_path)) child_path else dir;
}

fn hasManifest(arena: Allocator, io: std.Io, dir: []const u8) !bool {
    const root_manifest = try std.Io.Dir.path.join(arena, &.{ dir, manifest.root_manifest_name });
    const dir_manifest = try std.Io.Dir.path.join(arena, &.{ dir, manifest.dir_manifest_path });
    return isRegularFile(io, root_manifest) or isRegularFile(io, dir_manifest);
}

fn isRegularFile(io: std.Io, path: []const u8) bool {
    const stat = cwd().statFile(io, path, .{}) catch return false;
    return stat.kind == .file;
}

pub const ZipFixtureEntry = struct {
    name: []const u8,
    data: []const u8 = "",
    unix_mode: u32 = 0,
};

pub fn buildStoredZip(arena: Allocator, fixture_entries: []const ZipFixtureEntry) ![]u8 {
    const version_needed: u16 = 20;
    const made_by_unix: u16 = (3 << 8) | 20;
    var out: std.ArrayList(u8) = .empty;
    const local_offsets = try arena.alloc(u32, fixture_entries.len);
    for (fixture_entries, 0..) |fixture_entry, index| {
        local_offsets[index] = @intCast(out.items.len);
        try out.appendSlice(arena, &std.zip.local_file_header_sig);
        try appendLittle(arena, &out, u16, version_needed);
        try appendLittle(arena, &out, u16, 0);
        try appendLittle(arena, &out, u16, 0);
        try appendLittle(arena, &out, u16, 0);
        try appendLittle(arena, &out, u16, 0);
        try appendLittle(arena, &out, u32, std.hash.Crc32.hash(fixture_entry.data));
        try appendLittle(arena, &out, u32, @intCast(fixture_entry.data.len));
        try appendLittle(arena, &out, u32, @intCast(fixture_entry.data.len));
        try appendLittle(arena, &out, u16, @intCast(fixture_entry.name.len));
        try appendLittle(arena, &out, u16, 0);
        try out.appendSlice(arena, fixture_entry.name);
        try out.appendSlice(arena, fixture_entry.data);
    }
    const central_offset: u32 = @intCast(out.items.len);
    for (fixture_entries, 0..) |fixture_entry, index| {
        try out.appendSlice(arena, &std.zip.central_file_header_sig);
        try appendLittle(arena, &out, u16, made_by_unix);
        try appendLittle(arena, &out, u16, version_needed);
        try appendLittle(arena, &out, u16, 0);
        try appendLittle(arena, &out, u16, 0);
        try appendLittle(arena, &out, u16, 0);
        try appendLittle(arena, &out, u16, 0);
        try appendLittle(arena, &out, u32, std.hash.Crc32.hash(fixture_entry.data));
        try appendLittle(arena, &out, u32, @intCast(fixture_entry.data.len));
        try appendLittle(arena, &out, u32, @intCast(fixture_entry.data.len));
        try appendLittle(arena, &out, u16, @intCast(fixture_entry.name.len));
        try appendLittle(arena, &out, u16, 0);
        try appendLittle(arena, &out, u16, 0);
        try appendLittle(arena, &out, u16, 0);
        try appendLittle(arena, &out, u16, 0);
        try appendLittle(arena, &out, u32, fixture_entry.unix_mode << 16);
        try appendLittle(arena, &out, u32, local_offsets[index]);
        try out.appendSlice(arena, fixture_entry.name);
    }
    const central_size: u32 = @intCast(out.items.len - central_offset);
    try out.appendSlice(arena, &std.zip.end_record_sig);
    try appendLittle(arena, &out, u16, 0);
    try appendLittle(arena, &out, u16, 0);
    try appendLittle(arena, &out, u16, @intCast(fixture_entries.len));
    try appendLittle(arena, &out, u16, @intCast(fixture_entries.len));
    try appendLittle(arena, &out, u32, central_size);
    try appendLittle(arena, &out, u32, central_offset);
    try appendLittle(arena, &out, u16, 0);
    return out.toOwnedSlice(arena);
}

fn appendLittle(arena: Allocator, out: *std.ArrayList(u8), comptime Int: type, value: Int) !void {
    var bytes: [@sizeOf(Int)]u8 = undefined;
    std.mem.writeInt(Int, &bytes, value, .little);
    try out.appendSlice(arena, &bytes);
}

const testing = std.testing;

test "zip extraction writes files and directories and finds the manifest in a single child directory" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);

    const zip_bytes = try buildStoredZip(arena, &.{
        .{ .name = "acme-main/" },
        .{ .name = "acme-main/kimi.plugin.json", .data = "{\"name\":\"acme\"}" },
        .{ .name = "acme-main/bin/run.sh", .data = "#!/bin/sh\necho hi\n", .unix_mode = 0o100755 },
    });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "plugin.zip", .data = zip_bytes });
    const zip_path = try std.Io.Dir.path.join(arena, &.{ base, "plugin.zip" });
    const dest = try std.Io.Dir.path.join(arena, &.{ base, "tree" });

    const root = try extractZipFile(arena, zip_path, dest);
    try testing.expect(std.mem.endsWith(u8, root, "/tree/acme-main"));
    const script = try tmp.dir.readFileAlloc(testing.io, "tree/acme-main/bin/run.sh", arena, .limited(1024));
    try testing.expectEqualStrings("#!/bin/sh\necho hi\n", script);
    if (comptime std.Io.File.Permissions.has_executable_bit) {
        const stat = try tmp.dir.statFile(testing.io, "tree/acme-main/bin/run.sh", .{});
        try testing.expectEqual(@as(u32, 0o755), @as(u32, @intCast(stat.permissions.toMode() & 0o777)));
    }
}

test "zip extraction refuses an entry that climbs out of the destination" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);

    const zip_bytes = try buildStoredZip(arena, &.{
        .{ .name = "kimi.plugin.json", .data = "{\"name\":\"acme\"}" },
        .{ .name = "../escaped.txt", .data = "outside" },
    });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "plugin.zip", .data = zip_bytes });
    const zip_path = try std.Io.Dir.path.join(arena, &.{ base, "plugin.zip" });
    const dest = try std.Io.Dir.path.join(arena, &.{ base, "nested", "tree" });

    try testing.expectError(error.PluginArchivePathTraversal, extractZipFile(arena, zip_path, dest));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "nested/escaped.txt", .{}));
    try testing.expect(escapesDestination("/etc/passwd"));
    try testing.expect(escapesDestination("a/../../b"));
    try testing.expect(escapesDestination("C:\\evil"));
    try testing.expect(!escapesDestination("a/b..c/d"));
}

test "zip extraction reports bytes that are not a zip archive" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "plugin.zip", .data = "<html>not a zip</html>" });
    const zip_path = try std.Io.Dir.path.join(arena, &.{ base, "plugin.zip" });
    const dest = try std.Io.Dir.path.join(arena, &.{ base, "tree" });

    try testing.expectError(error.PluginArchiveInvalid, extractZipFile(arena, zip_path, dest));
}

test "the plugin root stays the extraction directory when the manifest is at the top or the children are ambiguous" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);

    try tmp.dir.createDirPath(testing.io, "top/child");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "top/kimi.plugin.json", .data = "{\"name\":\"top\"}" });
    const top = try std.Io.Dir.path.join(arena, &.{ base, "top" });
    try testing.expectEqualStrings(top, try detectPluginRoot(arena, top));

    try tmp.dir.createDirPath(testing.io, "two/a");
    try tmp.dir.createDirPath(testing.io, "two/b");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "two/a/kimi.plugin.json", .data = "{\"name\":\"a\"}" });
    const two = try std.Io.Dir.path.join(arena, &.{ base, "two" });
    try testing.expectEqualStrings(two, try detectPluginRoot(arena, two));

    try tmp.dir.createDirPath(testing.io, "one/only/.kimi-plugin");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "one/only/.kimi-plugin/plugin.json", .data = "{\"name\":\"only\"}" });
    const one = try std.Io.Dir.path.join(arena, &.{ base, "one" });
    try testing.expect(std.mem.endsWith(u8, try detectPluginRoot(arena, one), "/one/only"));
}
