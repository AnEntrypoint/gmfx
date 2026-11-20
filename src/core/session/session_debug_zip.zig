const std = @import("std");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;

pub const global_log_entry_name = "logs/global/trace.log";
const manifest_entry_name = "manifest.json";
const session_json_name = "session.json";
const max_file_bytes: usize = 1 << 30;
const max_entries: usize = std.math.maxInt(u16);
const zip_version: u16 = 20;
const zip_utf8_flag: u16 = 0x0800;
const zip_store_method: u16 = 0;
const zip_dos_time: u16 = 0;
const zip_dos_date: u16 = 0x0021;
const local_header_signature: u32 = 0x04034b50;
const central_header_signature: u32 = 0x02014b50;
const end_record_signature: u32 = 0x06054b50;
const local_header_len: usize = 30;
const central_header_len: usize = 46;
const end_record_len: usize = 22;

pub const Options = struct {
    include_global_log: bool = true,
    global_log_path: ?[]const u8 = null,
    fx_version: []const u8 = "",
};

pub const Entry = struct {
    name: []const u8,
    data: []const u8,
};

const SessionMeta = struct {
    workspace_root: ?[]const u8 = null,
    created_at_ms: ?i64 = null,
    updated_at_ms: ?i64 = null,
};

const ManifestFile = struct {
    path: []const u8,
    size: u64,
};

const Manifest = struct {
    session_id: []const u8,
    workspace_root: ?[]const u8,
    created_at_ms: ?i64,
    updated_at_ms: ?i64,
    fx_version: []const u8,
    include_global_log: bool,
    global_log_path: ?[]const u8,
    files: []const ManifestFile,
};

pub fn writeSessionDebugZip(
    alloc: Allocator,
    session_dir: []const u8,
    output_path: []const u8,
    options: Options,
) ![]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = io_mod.getIo();

    var dir = try std.Io.Dir.cwd().openDir(io, session_dir, .{ .iterate = true });
    defer dir.close(io);

    const meta = try readSessionMeta(arena, io, dir);
    var entries: std.ArrayList(Entry) = .empty;
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const name = try zipName(arena, entry.path);
        const data = try dir.readFileAlloc(io, entry.path, arena, .limited(max_file_bytes));
        try entries.append(arena, .{ .name = name, .data = data });
    }
    std.mem.sort(Entry, entries.items, {}, entryLessThan);

    if (options.include_global_log) {
        if (options.global_log_path) |path| {
            if (try readOptionalFile(arena, io, path)) |data| {
                try entries.append(arena, .{ .name = global_log_entry_name, .data = data });
            }
        }
    }

    const files = try arena.alloc(ManifestFile, entries.items.len);
    for (entries.items, files) |entry, *file| {
        file.* = .{ .path = entry.name, .size = entry.data.len };
    }
    const included_log = hasEntry(entries.items, global_log_entry_name);
    const manifest = Manifest{
        .session_id = lastComponent(session_dir),
        .workspace_root = meta.workspace_root,
        .created_at_ms = meta.created_at_ms,
        .updated_at_ms = meta.updated_at_ms,
        .fx_version = options.fx_version,
        .include_global_log = included_log,
        .global_log_path = if (included_log) global_log_entry_name else null,
        .files = files,
    };
    var manifest_out: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(manifest, .{}, &manifest_out.writer);

    var archive_entries: std.ArrayList(Entry) = .empty;
    try archive_entries.append(arena, .{ .name = manifest_entry_name, .data = manifest_out.written() });
    try archive_entries.appendSlice(arena, entries.items);

    const archive = try buildArchive(arena, archive_entries.items);
    var file = try std.Io.Dir.cwd().createFile(io, output_path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, archive);
    return output_path;
}

pub fn buildArchive(alloc: Allocator, entries: []const Entry) ![]u8 {
    if (entries.len > max_entries) return error.TooManyEntries;
    const crcs = try alloc.alloc(u32, entries.len);
    defer alloc.free(crcs);
    const offsets = try alloc.alloc(u32, entries.len);
    defer alloc.free(offsets);

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    for (entries, crcs, offsets) |entry, *crc, *offset| {
        if (entry.name.len > std.math.maxInt(u16) or entry.data.len > std.math.maxInt(u32)) {
            return error.EntryTooLarge;
        }
        offset.* = try archiveOffset(out.written().len);
        crc.* = std.hash.Crc32.hash(entry.data);
        var header: [local_header_len]u8 = undefined;
        writeLocalHeader(&header, entry, crc.*);
        try out.writer.writeAll(&header);
        try out.writer.writeAll(entry.name);
        try out.writer.writeAll(entry.data);
    }

    const central_start = out.written().len;
    for (entries, crcs, offsets) |entry, crc, offset| {
        var header: [central_header_len]u8 = undefined;
        writeCentralHeader(&header, entry, crc, offset);
        try out.writer.writeAll(&header);
        try out.writer.writeAll(entry.name);
    }
    const central_size = try archiveOffset(out.written().len - central_start);
    var end: [end_record_len]u8 = undefined;
    writeEndRecord(&end, entries.len, central_size, try archiveOffset(central_start));
    try out.writer.writeAll(&end);
    return out.toOwnedSlice();
}

fn archiveOffset(value: usize) error{ArchiveTooLarge}!u32 {
    return std.math.cast(u32, value) orelse error.ArchiveTooLarge;
}

fn putInt(comptime T: type, bytes: []u8, value: T) void {
    std.mem.writeInt(T, bytes[0..@sizeOf(T)], value, .little);
}

fn writeLocalHeader(buf: *[local_header_len]u8, entry: Entry, crc: u32) void {
    putInt(u32, buf[0..4], local_header_signature);
    putInt(u16, buf[4..6], zip_version);
    putInt(u16, buf[6..8], zip_utf8_flag);
    putInt(u16, buf[8..10], zip_store_method);
    putInt(u16, buf[10..12], zip_dos_time);
    putInt(u16, buf[12..14], zip_dos_date);
    putInt(u32, buf[14..18], crc);
    putInt(u32, buf[18..22], @intCast(entry.data.len));
    putInt(u32, buf[22..26], @intCast(entry.data.len));
    putInt(u16, buf[26..28], @intCast(entry.name.len));
    putInt(u16, buf[28..30], 0);
}

fn writeCentralHeader(buf: *[central_header_len]u8, entry: Entry, crc: u32, offset: u32) void {
    putInt(u32, buf[0..4], central_header_signature);
    putInt(u16, buf[4..6], zip_version);
    putInt(u16, buf[6..8], zip_version);
    putInt(u16, buf[8..10], zip_utf8_flag);
    putInt(u16, buf[10..12], zip_store_method);
    putInt(u16, buf[12..14], zip_dos_time);
    putInt(u16, buf[14..16], zip_dos_date);
    putInt(u32, buf[16..20], crc);
    putInt(u32, buf[20..24], @intCast(entry.data.len));
    putInt(u32, buf[24..28], @intCast(entry.data.len));
    putInt(u16, buf[28..30], @intCast(entry.name.len));
    putInt(u16, buf[30..32], 0);
    putInt(u16, buf[32..34], 0);
    putInt(u16, buf[34..36], 0);
    putInt(u16, buf[36..38], 0);
    putInt(u32, buf[38..42], 0);
    putInt(u32, buf[42..46], offset);
}

fn writeEndRecord(buf: *[end_record_len]u8, count: usize, size: u32, offset: u32) void {
    putInt(u32, buf[0..4], end_record_signature);
    putInt(u16, buf[4..6], 0);
    putInt(u16, buf[6..8], 0);
    putInt(u16, buf[8..10], @intCast(count));
    putInt(u16, buf[10..12], @intCast(count));
    putInt(u32, buf[12..16], size);
    putInt(u32, buf[16..20], offset);
    putInt(u16, buf[20..22], 0);
}

fn readSessionMeta(arena: Allocator, io: std.Io, dir: std.Io.Dir) !SessionMeta {
    const bytes = dir.readFileAlloc(io, session_json_name, arena, .limited(max_file_bytes)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch return .{};
    if (value != .object) return .{};
    return .{
        .workspace_root = stringField(value.object, "workspace_root"),
        .created_at_ms = integerField(value.object, "created_at_ms"),
        .updated_at_ms = integerField(value.object, "updated_at_ms"),
    };
}

fn readOptionalFile(arena: Allocator, io: std.Io, path: []const u8) !?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_file_bytes)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn integerField(object: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = object.get(key) orelse return null;
    return if (value == .integer) value.integer else null;
}

fn hasEntry(entries: []const Entry, name: []const u8) bool {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return true;
    }
    return false;
}

fn zipName(alloc: Allocator, path: []const u8) ![]u8 {
    const name = try alloc.dupe(u8, path);
    for (name) |*byte| {
        if (byte.* == std.Io.Dir.path.sep) byte.* = '/';
    }
    return name;
}

fn lastComponent(path: []const u8) []const u8 {
    return std.Io.Dir.path.basename(path);
}

fn entryLessThan(_: void, a: Entry, b: Entry) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

const ParsedEntry = struct {
    name: []const u8,
    data: []const u8,
    crc: u32,
    local_offset: u32,
};

fn parseArchive(alloc: Allocator, bytes: []const u8) ![]ParsedEntry {
    if (bytes.len < end_record_len) return error.TruncatedArchive;
    const end = bytes.len - end_record_len;
    if (std.mem.readInt(u32, bytes[end..][0..4], .little) != end_record_signature) return error.MissingEndRecord;
    const count = std.mem.readInt(u16, bytes[end + 10 ..][0..2], .little);
    const central_size = std.mem.readInt(u32, bytes[end + 12 ..][0..4], .little);
    const central_offset = std.mem.readInt(u32, bytes[end + 16 ..][0..4], .little);
    if (@as(usize, central_offset) + central_size != end) return error.BadCentralDirectory;

    const parsed = try alloc.alloc(ParsedEntry, count);
    errdefer alloc.free(parsed);
    var cursor: usize = central_offset;
    for (parsed) |*item| {
        const header = bytes[cursor..];
        if (std.mem.readInt(u32, header[0..4], .little) != central_header_signature) return error.BadCentralHeader;
        const crc = std.mem.readInt(u32, header[16..20], .little);
        const size = std.mem.readInt(u32, header[20..24], .little);
        const name_len = std.mem.readInt(u16, header[28..30], .little);
        const extra_len = std.mem.readInt(u16, header[30..32], .little);
        const comment_len = std.mem.readInt(u16, header[32..34], .little);
        const local_offset = std.mem.readInt(u32, header[42..46], .little);
        const name = header[central_header_len..][0..name_len];
        cursor += central_header_len + name_len + extra_len + comment_len;

        const local = bytes[local_offset..];
        if (std.mem.readInt(u32, local[0..4], .little) != local_header_signature) return error.BadLocalHeader;
        const local_name_len = std.mem.readInt(u16, local[26..28], .little);
        const local_extra_len = std.mem.readInt(u16, local[28..30], .little);
        const local_name = local[local_header_len..][0..local_name_len];
        if (!std.mem.eql(u8, name, local_name)) return error.NameMismatch;
        const data_start = local_header_len + local_name_len + local_extra_len;
        item.* = .{
            .name = name,
            .data = local[data_start..][0..size],
            .crc = crc,
            .local_offset = local_offset,
        };
    }
    if (cursor != end) return error.BadCentralDirectory;
    return parsed;
}

fn findEntry(entries: []const ParsedEntry, name: []const u8) ?ParsedEntry {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

const session_fixture =
    \\{"workspace_root":"/work/app","created_at_ms":100,"updated_at_ms":200}
    \\
;

test "debug zip writes a manifest and the session files" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "session/attachments");
    try tmp.dir.writeFile(io, .{ .sub_path = "session/session.json", .data = session_fixture });
    try tmp.dir.writeFile(io, .{ .sub_path = "session/events.jsonl", .data = "{\"seq\":1}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "session/attachments/note.txt", .data = "note" });

    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const session_dir = try std.Io.Dir.path.join(alloc, &.{ root, "session" });
    defer alloc.free(session_dir);
    const output = try std.Io.Dir.path.join(alloc, &.{ root, "debug.zip" });
    defer alloc.free(output);

    const written = try writeSessionDebugZip(alloc, session_dir, output, .{ .fx_version = "0.0.0-test" });
    try std.testing.expectEqualStrings(output, written);

    const bytes = try tmp.dir.readFileAlloc(io, "debug.zip", alloc, .limited(1 << 20));
    defer alloc.free(bytes);
    const entries = try parseArchive(alloc, bytes);
    defer alloc.free(entries);

    const manifest_entry = findEntry(entries, manifest_entry_name) orelse return error.MissingManifest;
    const session_entry = findEntry(entries, "session.json") orelse return error.MissingSessionFile;
    try std.testing.expectEqualStrings(session_fixture, session_entry.data);
    try std.testing.expectEqualStrings("{\"seq\":1}\n", (findEntry(entries, "events.jsonl") orelse return error.MissingSessionFile).data);
    try std.testing.expectEqualStrings("note", (findEntry(entries, "attachments/note.txt") orelse return error.MissingSessionFile).data);

    var manifest = try std.json.parseFromSlice(std.json.Value, alloc, manifest_entry.data, .{});
    defer manifest.deinit();
    const object = manifest.value.object;
    try std.testing.expectEqualStrings("session", object.get("session_id").?.string);
    try std.testing.expectEqualStrings("/work/app", object.get("workspace_root").?.string);
    try std.testing.expectEqual(@as(i64, 100), object.get("created_at_ms").?.integer);
    try std.testing.expectEqual(@as(i64, 200), object.get("updated_at_ms").?.integer);
    try std.testing.expectEqualStrings("0.0.0-test", object.get("fx_version").?.string);
    try std.testing.expectEqual(@as(usize, 3), object.get("files").?.array.items.len);
}

test "debug zip omits the global log when asked" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "session");
    try tmp.dir.writeFile(io, .{ .sub_path = "session/session.json", .data = session_fixture });
    try tmp.dir.writeFile(io, .{ .sub_path = "trace.log", .data = "global log line\n" });

    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const session_dir = try std.Io.Dir.path.join(alloc, &.{ root, "session" });
    defer alloc.free(session_dir);
    const trace_path = try std.Io.Dir.path.join(alloc, &.{ root, "trace.log" });
    defer alloc.free(trace_path);

    const without_path = try std.Io.Dir.path.join(alloc, &.{ root, "without.zip" });
    defer alloc.free(without_path);
    _ = try writeSessionDebugZip(alloc, session_dir, without_path, .{
        .include_global_log = false,
        .global_log_path = trace_path,
    });
    const without_bytes = try tmp.dir.readFileAlloc(io, "without.zip", alloc, .limited(1 << 20));
    defer alloc.free(without_bytes);
    const without_entries = try parseArchive(alloc, without_bytes);
    defer alloc.free(without_entries);
    try std.testing.expect(findEntry(without_entries, global_log_entry_name) == null);

    const with_path = try std.Io.Dir.path.join(alloc, &.{ root, "with.zip" });
    defer alloc.free(with_path);
    _ = try writeSessionDebugZip(alloc, session_dir, with_path, .{
        .include_global_log = true,
        .global_log_path = trace_path,
    });
    const with_bytes = try tmp.dir.readFileAlloc(io, "with.zip", alloc, .limited(1 << 20));
    defer alloc.free(with_bytes);
    const with_entries = try parseArchive(alloc, with_bytes);
    defer alloc.free(with_entries);
    const log_entry = findEntry(with_entries, global_log_entry_name) orelse return error.MissingGlobalLog;
    try std.testing.expectEqualStrings("global log line\n", log_entry.data);
}

test "debug zip central directory matches the entries" {
    const alloc = std.testing.allocator;
    const inputs = [_]Entry{
        .{ .name = "manifest.json", .data = "{}" },
        .{ .name = "attachments/a.bin", .data = "payload-bytes" },
        .{ .name = "events.jsonl", .data = "line\n" },
    };
    const bytes = try buildArchive(alloc, &inputs);
    defer alloc.free(bytes);
    const parsed = try parseArchive(alloc, bytes);
    defer alloc.free(parsed);

    try std.testing.expectEqual(inputs.len, parsed.len);
    for (inputs, parsed) |input, entry| {
        try std.testing.expectEqualStrings(input.name, entry.name);
        try std.testing.expectEqualStrings(input.data, entry.data);
        try std.testing.expectEqual(std.hash.Crc32.hash(input.data), entry.crc);
    }
    try std.testing.expectEqual(@as(u32, 0), parsed[0].local_offset);
    try std.testing.expect(parsed[1].local_offset > parsed[0].local_offset);
}
