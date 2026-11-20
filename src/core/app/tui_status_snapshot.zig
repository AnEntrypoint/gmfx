const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const session_layout = @import("../session/session_layout.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const browser_route = @import("../browser/route.zig");

const Allocator = std.mem.Allocator;

pub const snapshot_file_name = "status.json";
const temp_file_name = "status.json.tmp";
pub const max_bottom_line_bytes = 256;

const Payload = struct {
    bottomLine: []const u8,
    browser: ?browser_route.BrowserView,
    updatedAt: []const u8,
};

pub const Sent = struct {
    bytes: [max_bottom_line_bytes]u8 = undefined,
    len: usize = 0,
    browser: ?browser_route.BrowserView = null,
    recorded: bool = false,

    pub fn differs(self: *const Sent, text: []const u8, browser: ?browser_route.BrowserView) bool {
        return !self.recorded or
            !std.mem.eql(u8, self.bytes[0..self.len], text) or
            !sameBrowser(self.browser, browser);
    }

    pub fn record(self: *Sent, text: []const u8, browser: ?browser_route.BrowserView) void {
        @memcpy(self.bytes[0..text.len], text);
        self.len = text.len;
        self.browser = browser;
        self.recorded = true;
    }
};

fn sameBrowser(left: ?browser_route.BrowserView, right: ?browser_route.BrowserView) bool {
    const a = left orelse return right == null;
    const b = right orelse return false;
    return a.tabs == b.tabs and std.mem.eql(u8, a.state, b.state);
}

var last_sent: Sent = .{};

pub fn publish(alloc: Allocator, bottom_line: []const u8, browser: browser_route.BrowserView) void {
    if (builtin.is_test) return;
    publishToRuns(alloc, bottom_line, browser) catch |err| {
        debug_trace.logf("tui_status", "status snapshot write failed err={s}", .{@errorName(err)});
    };
}

fn publishToRuns(alloc: Allocator, bottom_line: []const u8, browser: browser_route.BrowserView) !void {
    if (!last_sent.differs(clamp(bottom_line), browser)) return;
    const path = (try runsRoot(alloc)) orelse return;
    defer alloc.free(path);
    const io = io_mod.getIo();
    try std.Io.Dir.cwd().createDirPath(io, path);
    var root = try std.Io.Dir.cwd().openDir(io, path, .{});
    defer root.close(io);
    _ = try publishTo(alloc, root, &last_sent, bottom_line, browser, io_mod.milliTimestamp());
}

pub fn publishTo(
    alloc: Allocator,
    root: std.Io.Dir,
    sent: *Sent,
    bottom_line: []const u8,
    browser: ?browser_route.BrowserView,
    now_ms: i64,
) !bool {
    const text = clamp(bottom_line);
    if (!sent.differs(text, browser)) return false;
    try writeSnapshot(alloc, root, text, browser, now_ms);
    sent.record(text, browser);
    return true;
}

fn clamp(text: []const u8) []const u8 {
    return text[0..@min(text.len, max_bottom_line_bytes)];
}

pub fn runsRoot(alloc: Allocator) !?[]u8 {
    const home = io_mod.homeDir() orelse return null;
    const sessions = try profile_paths.sessionsDir(alloc, home);
    defer alloc.free(sessions);
    return try std.Io.Dir.path.join(alloc, &.{ sessions, session_layout.sessions_v2_dir });
}

pub fn writeSnapshot(
    alloc: Allocator,
    root: std.Io.Dir,
    bottom_line: []const u8,
    browser: ?browser_route.BrowserView,
    now_ms: i64,
) !void {
    const io = io_mod.getIo();
    const updated_at = try formatIso8601(alloc, now_ms);
    defer alloc.free(updated_at);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try std.json.Stringify.value(Payload{
        .bottomLine = bottom_line,
        .browser = browser,
        .updatedAt = updated_at,
    }, .{}, &out.writer);
    try root.writeFile(io, .{ .sub_path = temp_file_name, .data = out.written() });
    try root.rename(temp_file_name, root, snapshot_file_name, io);
}

fn formatIso8601(alloc: Allocator, timestamp_ms: i64) ![]u8 {
    const epoch_secs: u64 = @intCast(@divTrunc(timestamp_ms, 1000));
    const epoch = std.time.epoch.EpochSeconds{ .secs = epoch_secs };
    const day = epoch.getDaySeconds();
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    return alloc.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        @backingInt(month_day.month),
        month_day.day_index + 1,
        day.getHoursIntoDay(),
        day.getMinutesIntoHour(),
        day.getSecondsIntoMinute(),
    });
}

test "tui_status snapshot writes the bottom line with a null browser" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var sent: Sent = .{};
    const wrote = try publishTo(alloc, tmp.dir, &sent, "fx 4 main idle", null, 1_700_000_000_000);
    try std.testing.expect(wrote);
    const bytes = try tmp.dir.readFileAlloc(io, snapshot_file_name, alloc, .limited(4096));
    defer alloc.free(bytes);
    try std.testing.expectEqualStrings(
        "{\"bottomLine\":\"fx 4 main idle\",\"browser\":null,\"updatedAt\":\"2023-11-14T22:13:20Z\"}",
        bytes,
    );
}

test "tui_status snapshot rewrites only when the bottom line changes" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var sent: Sent = .{};

    const first = try publishTo(alloc, tmp.dir, &sent, "fx 4 main idle", null, 1_700_000_000_000);
    try std.testing.expect(first);
    const same = try publishTo(alloc, tmp.dir, &sent, "fx 4 main idle", null, 1_700_000_060_000);
    try std.testing.expect(!same);
    const unchanged = try tmp.dir.readFileAlloc(io, snapshot_file_name, alloc, .limited(4096));
    defer alloc.free(unchanged);
    try std.testing.expect(std.mem.find(u8, unchanged, "2023-11-14T22:13:20Z") != null);

    const changed = try publishTo(alloc, tmp.dir, &sent, "fx 4 main busy", null, 1_700_000_060_000);
    try std.testing.expect(changed);
    const updated = try tmp.dir.readFileAlloc(io, snapshot_file_name, alloc, .limited(4096));
    defer alloc.free(updated);
    try std.testing.expectEqualStrings(
        "{\"bottomLine\":\"fx 4 main busy\",\"browser\":null,\"updatedAt\":\"2023-11-14T22:14:20Z\"}",
        updated,
    );
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(io, temp_file_name, .{}));
}

test "tui_status snapshot carries the browser value into the file" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const browser: browser_route.BrowserView = .{ .state = "idle", .tabs = 2 };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var sent: Sent = .{};
    try std.testing.expect(try publishTo(alloc, tmp.dir, &sent, "fx 4 main idle", browser, 1_700_000_000_000));
    const bytes = try tmp.dir.readFileAlloc(io, snapshot_file_name, alloc, .limited(4096));
    defer alloc.free(bytes);
    try std.testing.expectEqualStrings(
        "{\"bottomLine\":\"fx 4 main idle\",\"browser\":{\"state\":\"idle\",\"tabs\":2},\"updatedAt\":\"2023-11-14T22:13:20Z\"}",
        bytes,
    );
}

test "tui_status snapshot clamps the bottom line to its byte budget" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var long: [max_bottom_line_bytes + 44]u8 = undefined;
    @memset(&long, 'x');
    var sent: Sent = .{};
    try std.testing.expect(try publishTo(alloc, tmp.dir, &sent, &long, null, 1_700_000_000_000));
    const bytes = try tmp.dir.readFileAlloc(io, snapshot_file_name, alloc, .limited(4096));
    defer alloc.free(bytes);
    const expected = try std.fmt.allocPrint(alloc, "{{\"bottomLine\":\"{s}\",\"browser\":null,\"updatedAt\":\"2023-11-14T22:13:20Z\"}}", .{long[0..max_bottom_line_bytes]});
    defer alloc.free(expected);
    try std.testing.expectEqualStrings(expected, bytes);
}
