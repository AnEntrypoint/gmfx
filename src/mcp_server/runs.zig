const std = @import("std");
const io_mod = @import("../core/shared/io.zig");

const Allocator = std.mem.Allocator;

pub const log_file_name = "log.jsonl";
pub const log_tail_bytes = 64 * 1024;
pub const witness_scan_bytes = 256 * 1024;
pub const max_listed_sessions = 200;

const Run = struct {
    id: []const u8,
    witness: ?[]const u8,
};

const Candidate = struct {
    id: []const u8,
    mtime: i96,
};

pub fn openRoot(path: []const u8) ?std.Io.Dir {
    return std.Io.Dir.cwd().openDir(io_mod.getIo(), path, .{ .iterate = true }) catch null;
}

pub fn validId(id: []const u8) bool {
    if (id.len == 0 or id[0] == '.') return false;
    return std.mem.findScalar(u8, id, '/') == null and
        std.mem.findScalar(u8, id, '\\') == null and
        std.mem.findScalar(u8, id, 0) == null;
}

fn readTail(alloc: Allocator, root: std.Io.Dir, id: []const u8, limit: usize) ![]const u8 {
    const io = io_mod.getIo();
    const path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ id, log_file_name });
    var file = try root.openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const start = stat.size -| limit;
    const wanted = std.math.cast(usize, stat.size - start) orelse return error.FileTooBig;
    const buffer = try alloc.alloc(u8, wanted);
    const read = try file.readPositionalAll(io, buffer, start);
    return wholeLines(buffer[0..read], start > 0);
}

fn wholeLines(bytes: []const u8, cut_at_start: bool) []const u8 {
    if (!cut_at_start) return bytes;
    const newline = std.mem.findScalar(u8, bytes, '\n') orelse return bytes[bytes.len..];
    return bytes[newline + 1 ..];
}

pub fn readLog(alloc: Allocator, root: std.Io.Dir, id: []const u8) ![]const u8 {
    return readTail(alloc, root, id, log_tail_bytes);
}

pub fn logStat(root: std.Io.Dir, id: []const u8) !std.Io.File.Stat {
    var buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ id, log_file_name });
    return root.statFile(io_mod.getIo(), path, .{});
}

pub fn stampKey(root: std.Io.Dir) !u64 {
    var key: u64 = 0;
    var it = root.iterate();
    while (try it.next(io_mod.getIo())) |entry| {
        if (entry.kind != .directory or !validId(entry.name)) continue;
        const stat = logStat(root, entry.name) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        const mtime: i128 = stat.mtime.nanoseconds;
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(entry.name);
        hasher.update(std.mem.asBytes(&stat.size));
        hasher.update(std.mem.asBytes(&mtime));
        key +%= hasher.final();
    }
    return key;
}

fn witnessOf(alloc: Allocator, log: []const u8) !?[]const u8 {
    var lines = std.mem.splitBackwardsScalar(u8, log, '\n');
    while (lines.next()) |line| {
        if (std.mem.find(u8, line, "\"assistant\"") == null) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        if (!fieldIs(parsed.value, "kind", "item") or !fieldIs(parsed.value, "type", "assistant")) continue;
        const data = parsed.value.object.get("data") orelse continue;
        if (data != .object) continue;
        const text = data.object.get("text") orelse continue;
        if (text != .string or text.string.len == 0) continue;
        return try alloc.dupe(u8, text.string);
    }
    return null;
}

fn fieldIs(value: std.json.Value, name: []const u8, want: []const u8) bool {
    const field = value.object.get(name) orelse return false;
    return field == .string and std.mem.eql(u8, field.string, want);
}

pub fn witness(alloc: Allocator, root: std.Io.Dir, id: []const u8) !?[]const u8 {
    const log = readTail(alloc, root, id, witness_scan_bytes) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return witnessOf(alloc, log);
}

pub fn list(alloc: Allocator, root: std.Io.Dir) ![]Run {
    var candidates: std.ArrayList(Candidate) = .empty;
    var it = root.iterate();
    while (try it.next(io_mod.getIo())) |entry| {
        if (entry.kind != .directory or !validId(entry.name)) continue;
        const stat = logStat(root, entry.name) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        try candidates.append(alloc, .{ .id = try alloc.dupe(u8, entry.name), .mtime = stat.mtime.nanoseconds });
    }
    std.mem.sort(Candidate, candidates.items, {}, newerFirst);
    const shown = candidates.items[0..@min(candidates.items.len, max_listed_sessions)];

    var runs: std.ArrayList(Run) = .empty;
    for (shown) |candidate| {
        const text = witness(alloc, root, candidate.id) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => null,
        };
        try runs.append(alloc, .{ .id = candidate.id, .witness = text });
    }
    std.mem.sort(Run, runs.items, {}, lessThanId);
    return runs.toOwnedSlice(alloc);
}

fn newerFirst(_: void, a: Candidate, b: Candidate) bool {
    if (a.mtime != b.mtime) return a.mtime > b.mtime;
    return std.mem.lessThan(u8, a.id, b.id);
}

fn lessThanId(_: void, a: Run, b: Run) bool {
    return std.mem.lessThan(u8, a.id, b.id);
}

const assistant_line = "{\"v\":1,\"seq\":9,\"ts\":1,\"kind\":\"item\",\"turn\":1,\"type\":\"assistant\",\"data\":{\"text\":\"first answer\"},\"crc\":\"00000000\"}";
const final_line = "{\"v\":1,\"seq\":12,\"ts\":2,\"kind\":\"item\",\"turn\":2,\"type\":\"assistant\",\"data\":{\"text\":\"final answer\"},\"crc\":\"00000000\"}";
const tool_line = "{\"v\":1,\"seq\":13,\"ts\":3,\"kind\":\"item\",\"turn\":2,\"type\":\"tool_call\",\"data\":{\"tool_name\":\"assistant\"},\"crc\":\"00000000\"}";
const end_line = "{\"v\":1,\"seq\":14,\"ts\":4,\"kind\":\"turn_committed\",\"turn\":2,\"crc\":\"00000000\"}";

test "the witness of a session is its last assistant message" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const log = assistant_line ++ "\n" ++ final_line ++ "\n" ++ tool_line ++ "\n" ++ end_line ++ "\n";
    try std.testing.expectEqualStrings("final answer", (try witnessOf(arena, log)).?);
    try std.testing.expect(try witnessOf(arena, tool_line ++ "\n" ++ end_line ++ "\n") == null);
    try std.testing.expect(try witnessOf(arena, "not json \"assistant\"\n") == null);
}

test "a log longer than the tail is served from the first whole line inside the tail" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "long");
    var body: std.ArrayList(u8) = .empty;
    const pad: [1000]u8 = @splat('x');
    const filler = try std.fmt.allocPrint(arena, "{{\"v\":1,\"kind\":\"item\",\"type\":\"tool_result\",\"data\":{{\"pad\":\"{s}\"}}}}\n", .{&pad});
    while (body.items.len <= log_tail_bytes + filler.len) try body.appendSlice(arena, filler);
    try body.appendSlice(arena, final_line ++ "\n");
    try tmp.dir.writeFile(io, .{ .sub_path = "long/log.jsonl", .data = body.items });

    const tail = try readLog(arena, tmp.dir, "long");
    try std.testing.expect(tail.len <= log_tail_bytes);
    try std.testing.expect(std.mem.startsWith(u8, tail, "{\"v\":1,\"kind\":\"item\",\"type\":\"tool_result\""));
    try std.testing.expect(std.mem.endsWith(u8, tail, final_line ++ "\n"));
    try std.testing.expectEqualStrings("final answer", (try witness(arena, tmp.dir, "long")).?);
}

test "session ids that could leave the store or name its staging folder are refused" {
    try std.testing.expect(validId("-l6K2GNURzQX"));
    try std.testing.expect(!validId(""));
    try std.testing.expect(!validId("."));
    try std.testing.expect(!validId(".."));
    try std.testing.expect(!validId(".tmp"));
    try std.testing.expect(!validId("a/b"));
    try std.testing.expect(!validId("a\\b"));
}

test "the list keeps the newest sessions and marks the ones that have an answer" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "answered");
    try tmp.dir.writeFile(io, .{ .sub_path = "answered/log.jsonl", .data = final_line ++ "\n" ++ end_line ++ "\n" });
    try tmp.dir.createDirPath(io, "open");
    try tmp.dir.writeFile(io, .{ .sub_path = "open/log.jsonl", .data = tool_line ++ "\n" });
    try tmp.dir.createDirPath(io, "empty");
    try tmp.dir.createDirPath(io, ".tmp/staged");
    try tmp.dir.writeFile(io, .{ .sub_path = ".tmp/staged/log.jsonl", .data = final_line ++ "\n" });

    const runs = try list(arena, tmp.dir);
    try std.testing.expectEqual(@as(usize, 2), runs.len);
    try std.testing.expectEqualStrings("answered", runs[0].id);
    try std.testing.expectEqualStrings("final answer", runs[0].witness.?);
    try std.testing.expectEqualStrings("open", runs[1].id);
    try std.testing.expect(runs[1].witness == null);
}
