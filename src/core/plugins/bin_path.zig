const std = @import("std");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const manager = @import("manager.zig");

const Allocator = std.mem.Allocator;

pub const bin_dir_name = "bin";

pub fn publish(alloc: Allocator, home: ?[]const u8, sink: *const fn ([]const u8) void) void {
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const path_prefix = installedBinDirs(arena_state.allocator(), home) catch |err| {
        debug_trace.logf("plugins", "plugin bin directories unavailable err={s}", .{@errorName(err)});
        sink("");
        return;
    };
    sink(path_prefix);
}

fn installedBinDirs(arena: Allocator, home: ?[]const u8) ![]const u8 {
    const plugin_home = home orelse return "";
    return joinedBinDirs(arena, try manager.list(arena, plugin_home));
}

pub fn joinedBinDirs(arena: Allocator, plugins: []const manager.Plugin) ![]const u8 {
    var dirs: std.ArrayList([]const u8) = .empty;
    const io = io_mod.getIo();
    for (plugins) |plugin| {
        if (!plugin.record.enabled or !plugin.isOk()) continue;
        const dir = try std.Io.Dir.path.join(arena, &.{ plugin.record.root, bin_dir_name });
        const stat = std.Io.Dir.cwd().statFile(io, dir, .{}) catch continue;
        if (stat.kind != .directory) continue;
        try dirs.append(arena, dir);
    }
    return std.mem.join(arena, &.{std.Io.Dir.path.delimiter}, dirs.items);
}

var published_for_test: [512]u8 = undefined;
var published_for_test_len: usize = 0;

fn recordPublished(path_prefix: []const u8) void {
    published_for_test_len = @min(path_prefix.len, published_for_test.len);
    @memcpy(published_for_test[0..published_for_test_len], path_prefix[0..published_for_test_len]);
}

test "bin directories of enabled, loaded plugins are joined in plugin order and others are left out" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "a/bin");
    try tmp.dir.createDirPath(std.testing.io, "b/bin");
    try tmp.dir.createDirPath(std.testing.io, "off/bin");
    try tmp.dir.createDirPath(std.testing.io, "nobin");
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    const root_a = try std.Io.Dir.path.join(arena, &.{ base, "a" });
    const root_b = try std.Io.Dir.path.join(arena, &.{ base, "b" });
    const root_off = try std.Io.Dir.path.join(arena, &.{ base, "off" });
    const root_nobin = try std.Io.Dir.path.join(arena, &.{ base, "nobin" });

    const plugins = [_]manager.Plugin{
        .{ .record = .{ .id = "a", .root = root_a, .source = root_a }, .manifest = .{ .name = "a", .id = "a" } },
        .{ .record = .{ .id = "off", .root = root_off, .source = root_off, .enabled = false }, .manifest = .{ .name = "off", .id = "off" } },
        .{ .record = .{ .id = "nobin", .root = root_nobin, .source = root_nobin }, .manifest = .{ .name = "nobin", .id = "nobin" } },
        .{ .record = .{ .id = "broken", .root = root_b, .source = root_b }, .load_error = "No manifest" },
        .{ .record = .{ .id = "b", .root = root_b, .source = root_b }, .manifest = .{ .name = "b", .id = "b" } },
    };

    const expected = try std.fmt.allocPrint(arena, "{s}/bin{c}{s}/bin", .{ root_a, std.Io.Dir.path.delimiter, root_b });
    try std.testing.expectEqualStrings(expected, try joinedBinDirs(arena, &plugins));
    try std.testing.expectEqualStrings("", try joinedBinDirs(arena, plugins[1..4]));
}

test "publishing without a home or without installed plugins hands the sink an empty prefix" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);

    published_for_test_len = 7;
    publish(std.testing.allocator, null, recordPublished);
    try std.testing.expectEqual(@as(usize, 0), published_for_test_len);

    published_for_test_len = 7;
    publish(std.testing.allocator, home, recordPublished);
    try std.testing.expectEqual(@as(usize, 0), published_for_test_len);
}
