const std = @import("std");
const io_mod = @import("../shared/io.zig");
const session_event = @import("session_event.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const file_name = "history-cache.bin";

const magic = "fx-history-cache\x1a\n";

const format_version: u16 = 3;
const max_frame_bytes: u32 = 1024 * 1024 * 1024;
const max_frames: usize = 4 * 1024 * 1024;

const DecodeError = error{ InvalidCache, OutOfMemory };

const ByteCursor = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn take(self: *ByteCursor, count: usize) DecodeError![]const u8 {
        if (count > self.bytes.len - self.pos) return error.InvalidCache;
        const slice = self.bytes[self.pos..][0..count];
        self.pos += count;
        return slice;
    }

    fn takeInt(self: *ByteCursor) DecodeError!u64 {
        const raw = try self.take(8);
        return std.mem.readInt(u64, raw[0..8], .little);
    }
};

fn decodeAny(comptime T: type, alloc: Allocator, cur: *ByteCursor) DecodeError!T {
    switch (@typeInfo(T)) {
        .bool => return switch ((try cur.take(1))[0]) {
            0 => false,
            1 => true,
            else => error.InvalidCache,
        },
        .int => |info| {
            if (info.bits > 64) @compileError("snapshot codec: integer too wide: " ++ @typeName(T));
            const wide = try cur.takeInt();
            if (info.signedness == .signed) {
                const signed: i64 = @bitCast(wide);
                return std.math.cast(T, signed) orelse error.InvalidCache;
            }
            return std.math.cast(T, wide) orelse error.InvalidCache;
        },
        .@"enum" => |info| {
            const tag = (try cur.take(1))[0];
            const raw = std.math.cast(info.tag_type, tag) orelse return error.InvalidCache;
            inline for (@typeInfo(T).@"enum".field_values) |field_value| {
                if (field_value == raw) return @fromBackingInt(@intCast(raw));
            }
            return error.InvalidCache;
        },
        .optional => {
            return switch ((try cur.take(1))[0]) {
                0 => null,
                1 => try decodeAny(std.meta.Child(T), alloc, cur),
                else => error.InvalidCache,
            };
        },
        .pointer => |info| switch (info.size) {
            .slice => {
                const len = try decodeAny(u32, alloc, cur);
                if (info.child == u8) {
                    const bytes = try alloc.alloc(u8, len);
                    errdefer alloc.free(bytes);
                    @memcpy(bytes, try cur.take(len));
                    return bytes;
                }
                const items = try alloc.alloc(info.child, len);
                var initialized: usize = 0;
                errdefer {
                    for (items[0..initialized]) |item| freeAny(alloc, info.child, item);
                    alloc.free(items);
                }
                for (items) |*item| {
                    item.* = try decodeAny(info.child, alloc, cur);
                    initialized += 1;
                }
                return items;
            },
            else => @compileError("snapshot codec: unsupported pointer: " ++ @typeName(T)),
        },
        .array => |info| {
            var value: T = undefined;
            if (info.child == u8) {
                @memcpy(&value, try cur.take(info.len));
            } else {
                for (&value) |*item| item.* = try decodeAny(info.child, alloc, cur);
            }
            return value;
        },
        .@"struct" => |info| {
            var value: T = undefined;
            inline for (info.field_names, info.field_types) |field_name, field_type| {
                if (comptime absentFromCaches(T, field_name)) {
                    @field(value, field_name) = null;
                } else {
                    @field(value, field_name) = try decodeAny(field_type, alloc, cur);
                }
            }
            return value;
        },
        .@"union" => |info| {
            const tag_type = info.tag_type orelse
                @compileError("snapshot codec: untagged union: " ++ @typeName(T));
            const raw = (try cur.take(1))[0];
            _ = tag_type;
            const tag: std.meta.Tag(T) = tagblk: {
                inline for (@typeInfo(T).@"union".field_names) |field_name| {
                    const candidate = @field(std.meta.Tag(T), field_name);
                    if (@as(u64, @backingInt(candidate)) == raw) break :tagblk candidate;
                }
                return error.InvalidCache;
            };
            switch (tag) {
                inline else => |field_tag| {
                    const Payload = @TypeOf(@field(@as(T, undefined), @tagName(field_tag)));
                    const payload = try decodeAny(Payload, alloc, cur);
                    return @unionInit(T, @tagName(field_tag), payload);
                },
            }
        },
        .void => return {},
        else => @compileError("snapshot codec: unsupported type: " ++ @typeName(T)),
    }
}

fn absentFromCaches(comptime T: type, comptime field_name: []const u8) bool {
    return T == types.CommittedFilePresentation and std.mem.eql(u8, field_name, "review_lines");
}

fn freeAny(alloc: Allocator, comptime T: type, value: T) void {
    switch (@typeInfo(T)) {
        .optional => if (value) |inner| freeAny(alloc, std.meta.Child(T), inner),
        .pointer => |info| switch (info.size) {
            .slice => {
                if (info.child != u8) {
                    for (value) |item| freeAny(alloc, info.child, item);
                }
                alloc.free(value);
            },
            else => unreachable,
        },
        .@"struct" => |info| inline for (info.field_names, info.field_types) |field_name, field_type| {
            freeAny(alloc, field_type, @field(value, field_name));
        },
        .@"union" => switch (value) {
            inline else => |payload| freeAny(alloc, @TypeOf(payload), payload),
        },
        else => {},
    }
}

pub const FrameMeta = struct {
    file_offset: u64,
    log_offset: u64,
    log_bytes: u32,
    line_crc: u32,
};

const header_len_min = magic.len + 8 + 8 + 8;
const frame_log_fields_bytes = 3 * @sizeOf(u64);
const envelope_seq_offset = frame_log_fields_bytes + @sizeOf(u64);

pub const Verified = struct {
    file: std.Io.File,
    frames: []FrameMeta,
    covered_log_bytes: u64,
    last_seq: u64,

    pub fn deinit(self: *Verified, alloc: Allocator) void {
        alloc.free(self.frames);
        self.file.close(io_mod.getIo());
        self.* = undefined;
    }
};

pub fn openAndVerify(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    session_id: []const u8,
    log_file: std.Io.File,
    log_len: u64,
) !?Verified {
    var file = openCacheFile(dir, .read_only) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    var keep_file = false;
    defer if (!keep_file) file.close(io_mod.getIo());

    var frames: std.ArrayList(FrameMeta) = .empty;
    defer frames.deinit(alloc);

    var header: [header_len_min]u8 = undefined;
    const header_read = file.readPositionalAll(io_mod.getIo(), &header, 0) catch return null;
    if (header_read != header.len) return null;
    if (!std.mem.eql(u8, header[0..magic.len], magic)) return null;
    if (std.mem.readInt(u64, header[magic.len..][0..8], .little) != format_version) return null;
    if (std.mem.readInt(u64, header[magic.len + 8 ..][0..8], .little) != session_event.conversation_schema_version) return null;
    const id_len_wide = std.mem.readInt(u64, header[magic.len + 16 ..][0..8], .little);
    const id_len = std.math.cast(u32, id_len_wide) orelse return null;
    if (id_len != session_id.len) return null;
    const id_buf = alloc.alloc(u8, id_len) catch return error.OutOfMemory;
    defer alloc.free(id_buf);
    const id_read = file.readPositionalAll(io_mod.getIo(), id_buf, header_len_min) catch return null;
    if (id_read != id_len) return null;
    if (!std.mem.eql(u8, id_buf, session_id)) return null;

    var file_offset: u64 = header_len_min + @as(u64, id_len);
    var expected_seq: u64 = 1;
    var covered_log_bytes: u64 = 0;
    var tail_crc: u32 = 0;
    while (frames.items.len < max_frames) {
        var head: [8]u8 = undefined;
        const head_read = file.readPositionalAll(io_mod.getIo(), &head, file_offset) catch |err| return err;
        if (head_read != head.len) break;
        const frame_len = std.mem.readInt(u32, head[0..4], .little);
        if (frame_len < 4 or frame_len > max_frame_bytes) break;
        const want_crc = std.mem.readInt(u32, head[4..8], .little);
        const payload = alloc.alloc(u8, frame_len - 4) catch return error.OutOfMemory;
        defer alloc.free(payload);
        const read = file.readPositionalAll(io_mod.getIo(), payload, file_offset + 8) catch |err| return err;
        if (read != payload.len) break;
        if (std.hash.Crc32.hash(payload) != want_crc) break;
        if (payload.len < envelope_seq_offset + 8) break;
        const log_offset = std.mem.readInt(u64, payload[0..8], .little);
        const log_bytes_wide = std.mem.readInt(u64, payload[8..16], .little);
        const line_crc_wide = std.mem.readInt(u64, payload[16..24], .little);
        const log_bytes = std.math.cast(u32, log_bytes_wide) orelse break;
        const line_crc = std.math.cast(u32, line_crc_wide) orelse break;

        const seq = std.mem.readInt(u64, payload[envelope_seq_offset..][0..8], .little);
        if (seq != expected_seq) break;
        if (log_offset != covered_log_bytes) break;
        try frames.append(alloc, .{
            .file_offset = file_offset,
            .log_offset = log_offset,
            .log_bytes = log_bytes,
            .line_crc = line_crc,
        });
        covered_log_bytes += log_bytes;
        tail_crc = line_crc;
        expected_seq += 1;
        file_offset += 8 + payload.len;
    }
    if (frames.items.len == 0) return null;
    if (covered_log_bytes > log_len) return null;

    const tail = frames.items[frames.items.len - 1];
    const tail_bytes = alloc.alloc(u8, tail.log_bytes) catch return error.OutOfMemory;
    defer alloc.free(tail_bytes);
    const tail_read = log_file.readPositionalAll(io_mod.getIo(), tail_bytes, tail.log_offset) catch return null;
    if (tail_read != tail_bytes.len) return null;
    if (std.hash.Crc32.hash(tail_bytes) != tail_crc) return null;

    const owned = try frames.toOwnedSlice(alloc);
    keep_file = true;
    return .{
        .file = file,
        .frames = owned,
        .covered_log_bytes = covered_log_bytes,
        .last_seq = expected_seq - 1,
    };
}

pub const Cursor = struct {
    file: std.Io.File,
    frames: []const FrameMeta,
    index: usize = 0,

    pub fn reset(self: *Cursor) void {
        self.index = 0;
    }

    pub fn seekLogOffset(self: *Cursor, log_offset: u64) DecodeError!void {
        var lo: usize = 0;
        var hi: usize = self.frames.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.frames[mid].log_offset < log_offset) lo = mid + 1 else hi = mid;
        }
        if (lo >= self.frames.len or self.frames[lo].log_offset != log_offset) return error.InvalidCache;
        self.index = lo;
    }

    pub fn next(self: *Cursor, arena: Allocator) DecodeError!?session_event.ConversationEnvelope {
        if (self.index >= self.frames.len) return null;
        const meta = self.frames[self.index];
        var head: [8]u8 = undefined;
        _ = self.file.readPositionalAll(io_mod.getIo(), &head, meta.file_offset) catch return error.InvalidCache;
        const frame_len = std.mem.readInt(u32, head[0..4], .little);
        if (frame_len < 4 or frame_len > max_frame_bytes) return error.InvalidCache;
        const payload = arena.alloc(u8, frame_len - 4) catch return error.OutOfMemory;
        const read = self.file.readPositionalAll(io_mod.getIo(), payload, meta.file_offset + 8) catch return error.InvalidCache;
        if (read != payload.len) return error.InvalidCache;
        var cursor = ByteCursor{ .bytes = payload };
        _ = cursor.takeInt() catch return error.InvalidCache;
        _ = cursor.takeInt() catch return error.InvalidCache;
        _ = cursor.takeInt() catch return error.InvalidCache;
        const envelope = try decodeAny(session_event.ConversationEnvelope, arena, &cursor);
        if (cursor.pos != cursor.bytes.len) return error.InvalidCache;
        self.index += 1;
        return envelope;
    }
};

fn openCacheFile(dir: *io_mod.VerifiedDir, mode: std.Io.Dir.OpenFileOptions.Mode) !std.Io.File {
    var file = try dir.dir.openFile(io_mod.getIo(), file_name, .{
        .mode = mode,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    });
    errdefer file.close(io_mod.getIo());
    const stat = try file.stat(io_mod.getIo());
    if (stat.kind != .file or stat.nlink != 1) return error.HistoryCacheUnsafe;
    if (mode == .read_write and stat.permissions.toMode() & 0o777 != 0o600)
        return error.HistoryCachePermissionsUnsupported;
    return file;
}

const fixture_session_id = "rtXn8_Z6_NNt";

fn copyFixtureSession(alloc: Allocator, dir: std.Io.Dir) ![]u8 {
    const io = std.testing.io;

    const path = @import("test_paths").source_root ++ "/../tests/fixtures/v1-sessions/remembered/sessions/" ++ fixture_session_id;
    var source = try std.Io.Dir.cwd().openDir(io, path, .{});
    defer source.close(io);
    const cache = try source.readFileAlloc(io, file_name, alloc, .limited(1 << 20));
    defer alloc.free(cache);
    try dir.writeFile(io, .{ .sub_path = file_name, .data = cache });
    const log = try source.readFileAlloc(io, "events.jsonl", alloc, .limited(1 << 20));
    errdefer alloc.free(log);
    try dir.writeFile(io, .{ .sub_path = "events.jsonl", .data = log });
    return log;
}

test "history snapshot codec rejects a truncated payload" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const log = try copyFixtureSession(alloc, tmp.dir);
    defer alloc.free(log);
    var dir: io_mod.VerifiedDir = .{ .dir = tmp.dir };
    var log_file = try tmp.dir.openFile(std.testing.io, "events.jsonl", .{});
    defer log_file.close(std.testing.io);
    var verified = (try openAndVerify(alloc, &dir, fixture_session_id, log_file, log.len)).?;
    defer verified.deinit(alloc);

    var head: [8]u8 = undefined;
    _ = try verified.file.readPositionalAll(std.testing.io, &head, verified.frames[0].file_offset);
    const payload = try alloc.alloc(u8, std.mem.readInt(u32, head[0..4], .little) - 4);
    defer alloc.free(payload);
    _ = try verified.file.readPositionalAll(std.testing.io, payload, verified.frames[0].file_offset + 8);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var cursor = ByteCursor{ .bytes = payload[0 .. payload.len - 3] };
    for (0..3) |_| _ = try cursor.takeInt();
    try std.testing.expectError(error.InvalidCache, decodeAny(session_event.ConversationEnvelope, arena.allocator(), &cursor));

    cursor = .{ .bytes = payload };
    for (0..3) |_| _ = try cursor.takeInt();
    const decoded = try decodeAny(session_event.ConversationEnvelope, arena.allocator(), &cursor);
    try std.testing.expectEqual(@as(u64, 1), decoded.seq);
}

test "history snapshot verify, cursor, and watermark authority" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const log = try copyFixtureSession(alloc, tmp.dir);
    defer alloc.free(log);
    var dir: io_mod.VerifiedDir = .{ .dir = tmp.dir };
    var log_file = try tmp.dir.openFile(std.testing.io, "events.jsonl", .{});
    defer log_file.close(std.testing.io);

    var verified = (try openAndVerify(alloc, &dir, fixture_session_id, log_file, log.len)).?;
    defer verified.deinit(alloc);
    try std.testing.expectEqual(@as(u64, log.len), verified.covered_log_bytes);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var cursor = Cursor{ .file = verified.file, .frames = verified.frames };
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, log, "\n"), '\n');
    var count: usize = 0;
    var second_offset: ?u64 = null;
    while (lines.next()) |line| : (count += 1) {
        if (count == 1) second_offset = lines.index.? - line.len - 1;
        const saved = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), line, .{});
        const decoded = (try cursor.next(arena.allocator())).?;
        try std.testing.expectEqual(@as(u64, @intCast(saved.object.get("seq").?.integer)), decoded.seq);
        try std.testing.expectEqualStrings(saved.object.get("event").?.object.keys()[0], @tagName(decoded.event));
    }
    try std.testing.expect(count >= 2);
    try std.testing.expect((try cursor.next(arena.allocator())) == null);
    try std.testing.expectEqual(count, verified.frames.len);
    try std.testing.expectEqual(@as(u64, count), verified.last_seq);
    try cursor.seekLogOffset(second_offset.?);
    try std.testing.expectEqual(@as(u64, 2), (try cursor.next(arena.allocator())).?.seq);

    try std.testing.expect((try openAndVerify(alloc, &dir, "another-id12", log_file, log.len)) == null);
    try std.testing.expect((try openAndVerify(alloc, &dir, fixture_session_id, log_file, log.len - 1)) == null);
    {
        var mutable = try tmp.dir.openFile(std.testing.io, "events.jsonl", .{ .mode = .read_write });
        defer mutable.close(std.testing.io);
        try mutable.writePositionalAll(std.testing.io, "X", log.len - 2);
    }
    try std.testing.expect((try openAndVerify(alloc, &dir, fixture_session_id, log_file, log.len)) == null);
}

test "history snapshot rejects version two caches before decoding" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const log = try copyFixtureSession(alloc, tmp.dir);
    defer alloc.free(log);
    var dir: io_mod.VerifiedDir = .{ .dir = tmp.dir };
    var log_file = try tmp.dir.openFile(std.testing.io, "events.jsonl", .{});
    defer log_file.close(std.testing.io);
    {
        var cache = try tmp.dir.openFile(std.testing.io, file_name, .{ .mode = .read_write });
        defer cache.close(std.testing.io);
        var version: [8]u8 = undefined;
        std.mem.writeInt(u64, &version, 2, .little);
        try cache.writePositionalAll(std.testing.io, &version, magic.len);
    }
    var verified = try openAndVerify(alloc, &dir, fixture_session_id, log_file, log.len);
    defer if (verified) |*cache| cache.deinit(alloc);
    try std.testing.expect(verified == null);
}

test "history snapshot verification tolerates a torn tail as a shorter prefix" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const log = try copyFixtureSession(alloc, tmp.dir);
    defer alloc.free(log);
    var dir: io_mod.VerifiedDir = .{ .dir = tmp.dir };
    var log_file = try tmp.dir.openFile(std.testing.io, "events.jsonl", .{});
    defer log_file.close(std.testing.io);
    const frames = blk: {
        var whole = (try openAndVerify(alloc, &dir, fixture_session_id, log_file, log.len)).?;
        defer whole.deinit(alloc);
        break :blk whole.frames.len;
    };
    {
        var cache = try tmp.dir.openFile(std.testing.io, file_name, .{ .mode = .read_write });
        defer cache.close(std.testing.io);
        const fake: [8]u8 = .{ 0, 64, 0, 0, 1, 2, 3, 4 };
        try cache.writePositionalAll(std.testing.io, &fake, try cache.length(std.testing.io));
    }
    var verified = (try openAndVerify(alloc, &dir, fixture_session_id, log_file, log.len)).?;
    defer verified.deinit(alloc);
    try std.testing.expectEqual(frames, verified.frames.len);
    try std.testing.expectEqual(@as(u64, frames), verified.last_seq);
}
