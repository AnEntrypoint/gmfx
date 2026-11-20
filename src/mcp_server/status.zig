const std = @import("std");
const io_mod = @import("../core/shared/io.zig");
const jsonrpc = @import("../acp/jsonrpc.zig");
const runs = @import("runs.zig");

const Allocator = std.mem.Allocator;

pub const snapshot_file_name = "status.json";
const snapshot_max_bytes = 256 * 1024;

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
};

pub const tools = [_]Tool{
    .{ .name = "fx_status", .description = "fx live status: the TUI bottom line, the newest run without a final answer, and the browser state." },
    .{ .name = "fx_run_active", .description = "The newest run without a final answer, as { id, witness }, or null." },
    .{ .name = "fx_browser_state", .description = "The browser state the fx TUI last reported, or null." },
};

pub fn isTool(name: []const u8) bool {
    for (tools) |tool| {
        if (std.mem.eql(u8, tool.name, name)) return true;
    }
    return false;
}

pub fn write(alloc: Allocator, root: ?std.Io.Dir, name: []const u8, w: *std.Io.Writer) !void {
    if (std.mem.eql(u8, name, "fx_run_active")) return writeActiveRun(alloc, root, w);
    if (std.mem.eql(u8, name, "fx_browser_state")) return writeField(alloc, root, "browser", w);
    return writeStatus(alloc, root, w);
}

fn writeStatus(alloc: Allocator, root: ?std.Io.Dir, w: *std.Io.Writer) !void {
    const snapshot = readSnapshot(alloc, root);
    try w.writeAll("{\"bottomLine\":");
    try writeOptionalString(w, fieldOf(snapshot, "bottomLine"));
    try w.writeAll(",\"activeRun\":");
    try writeActiveRun(alloc, root, w);
    try w.writeAll(",\"browser\":");
    try writeOptionalValue(w, fieldOf(snapshot, "browser"));
    try w.writeAll(",\"updatedAt\":");
    try writeOptionalValue(w, fieldOf(snapshot, "updatedAt"));
    try w.writeByte('}');
}

fn writeField(alloc: Allocator, root: ?std.Io.Dir, field: []const u8, w: *std.Io.Writer) !void {
    try writeOptionalValue(w, fieldOf(readSnapshot(alloc, root), field));
}

fn writeActiveRun(alloc: Allocator, root: ?std.Io.Dir, w: *std.Io.Writer) !void {
    const dir = root orelse return w.writeAll("null");
    const list = try runs.list(alloc, dir);
    for (list) |run| {
        if (run.witness != null) return w.writeAll("null");
        try w.writeAll("{\"id\":");
        try jsonrpc.writeJsonStr(run.id, w);
        try w.writeAll(",\"witness\":null}");
        return;
    }
    try w.writeAll("null");
}

fn readSnapshot(alloc: Allocator, root: ?std.Io.Dir) ?std.json.Value {
    const dir = root orelse return null;
    const io = io_mod.getIo();
    var file = dir.openFile(io, snapshot_file_name, .{}) catch return null;
    defer file.close(io);
    const stat = file.stat(io) catch return null;
    if (stat.size > snapshot_max_bytes) return null;
    const size = std.math.cast(usize, stat.size) orelse return null;
    const buffer = alloc.alloc(u8, size) catch return null;
    const read = file.readPositionalAll(io, buffer, 0) catch return null;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, alloc, buffer[0..read], .{}) catch return null;
    if (parsed != .object) return null;
    return parsed;
}

fn fieldOf(snapshot: ?std.json.Value, name: []const u8) ?std.json.Value {
    const value = snapshot orelse return null;
    return value.object.get(name);
}

fn writeOptionalString(w: *std.Io.Writer, value: ?std.json.Value) !void {
    const found = value orelse return w.writeAll("null");
    if (found != .string) return w.writeAll("null");
    try jsonrpc.writeJsonStr(found.string, w);
}

fn writeOptionalValue(w: *std.Io.Writer, value: ?std.json.Value) !void {
    const found = value orelse return w.writeAll("null");
    try std.json.Stringify.value(found, .{}, w);
}

test "fx_status reports the open run and the snapshot the TUI wrote" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "open");
    try tmp.dir.writeFile(io, .{ .sub_path = "open/log.jsonl", .data = "{\"seq\":1,\"kind\":\"turn_started\",\"turn\":1}\n" });
    try tmp.dir.writeFile(io, .{
        .sub_path = snapshot_file_name,
        .data = "{\"bottomLine\":\"fx 4 main idle\",\"browser\":{\"state\":\"idle\",\"tabs\":2},\"updatedAt\":\"2026-11-15T18:00:00Z\"}",
    });

    var out: std.Io.Writer.Allocating = .init(arena);
    try write(arena, tmp.dir, "fx_status", &out.writer);
    try std.testing.expectEqualStrings(
        "{\"bottomLine\":\"fx 4 main idle\",\"activeRun\":{\"id\":\"open\",\"witness\":null},\"browser\":{\"state\":\"idle\",\"tabs\":2},\"updatedAt\":\"2026-11-15T18:00:00Z\"}",
        out.written(),
    );

    var browser: std.Io.Writer.Allocating = .init(arena);
    try write(arena, tmp.dir, "fx_browser_state", &browser.writer);
    try std.testing.expectEqualStrings("{\"state\":\"idle\",\"tabs\":2}", browser.written());
}

test "fx status tools answer null when there is no run root or snapshot" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.Io.Writer.Allocating = .init(arena);
    try write(arena, null, "fx_status", &out.writer);
    try std.testing.expectEqualStrings("{\"bottomLine\":null,\"activeRun\":null,\"browser\":null,\"updatedAt\":null}", out.written());
    var run: std.Io.Writer.Allocating = .init(arena);
    try write(arena, null, "fx_run_active", &run.writer);
    try std.testing.expectEqualStrings("null", run.written());
}
